import { expect, test } from "@playwright/test";

test("bug reports open the fork issue page without contacting the upstream service", async ({ page }) => {
  const upstreamRequests: string[] = [];
  page.on("request", request => { if (request.url().includes("report.rbxport.com")) upstreamRequests.push(request.url()); });
  await page.context().route("https://github.com/**", route => route.fulfill({ contentType: "text/html", body: "Fork issues" }));
  await page.goto("/");
  await page.getByRole("contentinfo").getByRole("button", { name: "Report bug", exact: true }).click();
  const report = page.getByRole("dialog", { name: "Report bug", exact: true });
  await expect(report.locator("iframe")).toHaveCount(0);
  await expect(report).toContainText("GitHub issues are public");
  const popup = page.waitForEvent("popup");
  await report.getByRole("button", { name: "Open GitHub issue" }).click();
  expect((await popup).url()).toBe("https://github.com/computergabe/rbxport/issues/new/choose");
  expect(upstreamRequests).toEqual([]);
  await report.getByRole("button", { name: "Close", exact: true }).click();
  await expect(report).toHaveCount(0);
});

test("Preferences offers the fork bug report dialog", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("banner").getByRole("button", { name: "Settings" }).click();
  const preferences = page.getByRole("dialog", { name: "Preferences", exact: true });
  await preferences.getByRole("navigation", { name: "Preference panes" }).getByRole("button", { name: "Report bug" }).click();
  const report = page.getByRole("dialog", { name: "Report bug", exact: true });
  await expect(report).toContainText("computergabe/rbxport");
  await report.getByRole("button", { name: "Close report" }).click();
  await expect(preferences).toBeVisible();
});
