defmodule Phoenix.LiveView.ResumeTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Resume
  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveView.Utils
  alias Phoenix.LiveViewTest.Support.Endpoint

  # Build a minimal socket that Resume can store and return
  defp dummy_socket do
    %Socket{
      endpoint: Endpoint,
      router: Phoenix.LiveViewTest.Support.Router,
      id: "test-socket-id",
      view: Phoenix.LiveViewTest.Support.ParamCounterLive
    }
  end

  defp dummy_socket(id, view) do
    %Socket{
      endpoint: Endpoint,
      router: Phoenix.LiveViewTest.Support.Router,
      id: id,
      view: view
    }
  end

  describe "issue/1" do
    test "returns {:ok, token} and registers the process" do
      socket = dummy_socket()
      assert {:ok, token} = Resume.issue(socket)
      assert is_binary(token)

      # Registry should have exactly one entry (the resume GenServer)
      # Verify by redeeming it immediately
      assert {:ok, %Socket{}} = Resume.redeem(token, Endpoint, socket.id, socket.view)
    end

    test "token is verifiable by the same endpoint" do
      socket = dummy_socket()
      assert {:ok, token} = Resume.issue(socket)
      assert {:ok, _socket} = Resume.redeem(token, Endpoint, socket.id, socket.view)
    end
  end

  describe "redeem/4" do
    test "returns {:ok, socket} and terminates the resume GenServer" do
      socket = dummy_socket()
      assert {:ok, token} = Resume.issue(socket)

      assert {:ok, taken} = Resume.redeem(token, Endpoint, socket.id, socket.view)
      assert %Socket{} = taken

      # Process is gone: second redeem must return :error
      :timer.sleep(10)
      assert :error = Resume.redeem(token, Endpoint, socket.id, socket.view)
    end

    test "second redeem returns :error (one-shot)" do
      socket = dummy_socket()
      {:ok, token} = Resume.issue(socket)
      assert {:ok, _} = Resume.redeem(token, Endpoint, socket.id, socket.view)
      assert :error = Resume.redeem(token, Endpoint, socket.id, socket.view)
    end

    test "garbage token returns :error" do
      assert :error = Resume.redeem("not-a-valid-token", Endpoint, "any-id", Elixir.SomeView)
    end

    test "token bound to id fails verify when id differs" do
      socket = dummy_socket("original-id", Phoenix.LiveViewTest.Support.ParamCounterLive)
      {:ok, token} = Resume.issue(socket)

      # Different id — must reject
      assert :error =
               Resume.redeem(
                 token,
                 Endpoint,
                 "different-id",
                 Phoenix.LiveViewTest.Support.ParamCounterLive
               )
    end

    test "token bound to view fails verify when view differs" do
      socket = dummy_socket("my-socket-id", Phoenix.LiveViewTest.Support.ParamCounterLive)
      {:ok, token} = Resume.issue(socket)

      # Different view module — must reject
      assert :error =
               Resume.redeem(
                 token,
                 Endpoint,
                 "my-socket-id",
                 Phoenix.LiveViewTest.Support.StatefulView
               )
    end

    test "token bound to correct id and view succeeds" do
      socket = dummy_socket("correct-id", Phoenix.LiveViewTest.Support.ParamCounterLive)
      {:ok, token} = Resume.issue(socket)

      assert {:ok, _} =
               Resume.redeem(
                 token,
                 Endpoint,
                 "correct-id",
                 Phoenix.LiveViewTest.Support.ParamCounterLive
               )
    end

    test "wrong version in token returns :error" do
      # sign a token with an unsupported version
      key = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      salt = Utils.salt!(Endpoint)

      bad_token =
        Phoenix.Token.sign(
          Endpoint,
          salt,
          {2, %{lv_resume_key: key, id: "id", view: SomeView}}
        )

      assert :error = Resume.redeem(bad_token, Endpoint, "id", SomeView)
    end
  end
end

# async: false because the tiny TTL is set via process-global Application env
# and read at issue/1 time, which would flake under concurrent tests.
defmodule Phoenix.LiveView.ResumeSyncTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Resume
  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveView.Utils
  alias Phoenix.LiveViewTest.Support.Endpoint

  defp dummy_socket do
    %Socket{
      endpoint: Endpoint,
      router: Phoenix.LiveViewTest.Support.Router,
      id: "sync-test-id",
      view: Phoenix.LiveViewTest.Support.ParamCounterLive
    }
  end

  describe "TTL-vs-redeem race" do
    @tag :capture_log
    test "redeem returns :error when holder pid dies before call" do
      # Prove the catch-arm in redeem/4 (~line 62-64 of resume.ex) handles a
      # dead holder pid without crashing the test process.
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 60_000)

      on_exit(fn ->
        Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
      end)

      socket = dummy_socket()
      {:ok, token} = Resume.issue(socket)

      # Look up the holder pid via the Registry key embedded in the token.
      {:ok, {1, %{lv_resume_key: key}}} =
        Phoenix.Token.verify(
          Endpoint,
          Utils.salt!(Endpoint),
          token,
          max_age: :infinity
        )

      [{holder_pid, _}] = Registry.lookup(Phoenix.LiveView.Resume.Registry, key)
      assert Process.alive?(holder_pid)

      # Stop the holder before redeeming — simulates the TTL race window.
      GenServer.stop(holder_pid, :normal)
      :timer.sleep(10)
      refute Process.alive?(holder_pid)

      # redeem must return :error, not crash the caller
      assert :error = Resume.redeem(token, Endpoint, socket.id, socket.view)
    end
  end

  describe "salt rotation rejection" do
    test "token signed with wrong salt returns :error" do
      socket = dummy_socket()
      {:ok, _token} = Resume.issue(socket)

      # Sign a structurally valid token with the wrong salt string.
      key = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      bad_token =
        Phoenix.Token.sign(
          Endpoint,
          "wrong-salt-string",
          {1, %{lv_resume_key: key, id: socket.id, view: socket.view}}
        )

      assert :error = Resume.redeem(bad_token, Endpoint, socket.id, socket.view)
    end
  end

  describe "TTL expiry" do
    @tag :capture_log
    test "expired resume token returns :error" do
      # Use a very short TTL so the process expires before we redeem it.
      # Application.put_env is process-global → kept in async: false module.
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5)

      on_exit(fn ->
        Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
      end)

      socket = dummy_socket()
      {:ok, token} = Resume.issue(socket)

      # Wait for TTL to fire
      :timer.sleep(50)

      assert :error = Resume.redeem(token, Endpoint, socket.id, socket.view)
    end

    @tag :capture_log
    test "token signed beyond max_age grace period returns :error" do
      # a token older than ttl + grace must be rejected by Phoenix.Token.verify/4
      Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 1)

      on_exit(fn ->
        Application.put_env(:phoenix_live_view, :resume, enabled: false, ttl: 5_000)
      end)

      socket = dummy_socket()
      {:ok, token} = Resume.issue(socket)

      # confirm the GenServer is dead after the TTL fires, which covers the
      # token-expiry path for the registry lookup
      :timer.sleep(20)

      assert :error = Resume.redeem(token, Endpoint, socket.id, socket.view)
    end
  end
end
