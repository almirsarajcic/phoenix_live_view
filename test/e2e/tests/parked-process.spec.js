// Skipped: warm mount is opt-in and default-off. Enabling it globally breaks
// connected-mount semantics across the suite (the warm path skips the connected
// mount/3, dropping connected-only subscriptions/timers). Re-enable once the
// split-mount design lands.
import { test, expect } from "../test-fixtures";
import { syncLV } from "../utils";

// addInitScript (not page.evaluate) so the observer re-arms after reload.
const installDetachObserver = async (page) => {
  await page.addInitScript(() => {
    window.__streamDetaches = [];
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.removedNodes) {
          if (node.nodeType === 1 && node.id) {
            window.__streamDetaches.push(node.id);
          }
        }
      }
    });
    const attach = () => {
      const usersContainer = document.getElementById("users");
      if (usersContainer) {
        observer.observe(usersContainer, { childList: true });
      } else {
        requestAnimationFrame(attach);
      }
    };
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", attach);
    } else {
      attach();
    }
  });
};

const getStreamDetaches = async (page) =>
  page.evaluate(() => window.__streamDetaches || []);

test.skip("join-patch stream children are NOT detached on warm reconnect", async ({
  page,
}) => {
  await installDetachObserver(page);

  await page.goto("/stream");
  await syncLV(page);

  const userIds = await page
    .locator("#users > *")
    .evaluateAll((nodes) => nodes.map((n) => n.id));
  expect(userIds.length).toBeGreaterThan(0);

  // tag the first child so we can find it again after the reload
  const firstId = userIds[0];
  await page.locator(`#${firstId}`).evaluate((el) => {
    el.setAttribute("data-park-tagged", "true");
  });

  // ignore detaches from the initial mount
  await page.evaluate(() => {
    window.__streamDetaches = [];
  });

  // reload drives a fresh dead render -> park -> warm WS join -> join-patch
  await page.reload();
  await syncLV(page);

  const taggedNode = page.locator(`#${firstId}`);
  await expect(taggedNode).toBeVisible();

  // no re-inserted stream child should have been detached during the join-patch
  const detaches = await getStreamDetaches(page);
  const reInsertedIds = await page
    .locator("#users > *")
    .evaluateAll((nodes) => nodes.map((n) => n.id));

  for (const id of reInsertedIds) {
    expect(detaches).not.toContain(
      id,
      `stream child #${id} was detached during join-patch`,
    );
  }
});

test.skip("stream items render correctly after warm reconnect", async ({
  page,
}) => {
  await page.goto("/stream");
  await syncLV(page);

  const beforeIds = await page
    .locator("#users > *")
    .evaluateAll((nodes) => nodes.map((n) => n.id));
  expect(beforeIds.length).toBeGreaterThan(0);

  // reload = warm reconnect via park
  await page.reload();
  await syncLV(page);

  const afterIds = await page
    .locator("#users > *")
    .evaluateAll((nodes) => nodes.map((n) => n.id));
  expect(afterIds.length).toBeGreaterThan(0);

  for (const id of beforeIds) {
    expect(afterIds).toContain(id);
  }
});
