from __future__ import annotations

from geo_operator.browser.plugins.base import PlatformObservation, RevalidationResult


class MockAIPlugin:
    name = "mock"
    phase = 0
    response_locator = "[data-testid='response']"

    def __init__(self, base_url: str, mode: str = "normal") -> None:
        self.url = f"{base_url.rstrip('/')}/mock-ai?mode={mode}"

    async def detect_login(self, page: object) -> bool:
        return not await page.locator("[data-testid='login-expired']").is_visible()

    async def detect_human_intervention(self, page: object) -> str | None:
        checks = (
            ("[data-testid='captcha']", "CAPTCHA"),
            ("[data-testid='login-expired']", "LOGIN_EXPIRED"),
            ("[data-testid='security-challenge']", "SECURITY_CHALLENGE"),
            ("[data-testid='rate-limit']", "RATE_LIMITED"),
            ("[data-testid='account-restricted']", "ACCOUNT_RESTRICTED"),
        )
        for selector, reason in checks:
            if await page.locator(selector).is_visible():
                return reason
        if await page.locator(self.response_locator).count() != 1:
            return "PAGE_ABNORMAL"
        return None

    async def open_platform(self, page: object) -> None:
        if not page.url.startswith(self.url):
            await page.goto(self.url, wait_until="domcontentloaded")

    async def send_query(self, page: object, prompt: str) -> None:
        await page.locator("[data-testid='prompt']").fill(prompt)
        await page.locator("[data-testid='send']").click()

    async def query_exists(self, page: object, prompt: str) -> bool:
        queries = page.locator("[data-testid='user-query']")
        for index in range(await queries.count()):
            if (await queries.nth(index).inner_text()).strip() == prompt.strip():
                return True
        return False

    async def observe_response(self, page: object) -> PlatformObservation:
        response = page.locator(self.response_locator)
        if await response.count() != 1:
            raise RuntimeError("PAGE_ABNORMAL")
        text = await response.inner_text()
        stop = page.locator("[data-testid='stop']")
        prompt = page.locator("[data-testid='prompt']")
        send = page.locator("[data-testid='send']")
        return PlatformObservation(
            response_text=text,
            streaming_indicator_absent=not await stop.is_visible(),
            stop_control_absent=not await stop.is_visible(),
            input_ready=await prompt.is_enabled() and await send.is_enabled(),
            response_text_stable=False,
            final_response_element_present=(await response.get_attribute("data-final") == "true"),
            platform_error_absent=await self.detect_human_intervention(page) is None,
        )

    async def delete_chat(self, page: object) -> None:
        await page.locator("[data-testid='delete-chat']").click()

    async def verify_chat_deleted(self, page: object) -> bool:
        return await page.locator("[data-testid='chat']").get_attribute("data-deleted") == "true"

    async def screenshot(self, page: object) -> bytes:
        return await page.screenshot(full_page=False, animations="disabled", timeout=2_000)

    async def revalidate(self, page: object, execution: dict[str, object]) -> RevalidationResult:
        reason = await self.detect_human_intervention(page)
        return RevalidationResult(
            safe=reason is None,
            resume_state=str(execution.get("resume_state")) if reason is None else None,
            pause_reason=reason,
        )
