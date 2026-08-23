import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

from geo_operator.browser.session import BrowserSessionManager, ManagedBrowser
from geo_operator.core.storage import ArtifactStore


class BrowserSessionRecoveryTestCase(unittest.IsolatedAsyncioTestCase):
    async def test_open_relaunches_after_operator_closed_existing_context(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifacts = ArtifactStore(Path(temporary) / "data")
            manager = BrowserSessionManager(artifacts, browser_channel="chrome")
            key = ("tenant-a", "doubao", "manual")

            stale_context = Mock()
            stale_context.cookies = AsyncMock(
                side_effect=Exception("Target page, context or browser has been closed")
            )
            stale_context.close = AsyncMock()
            stale_playwright = Mock()
            stale_playwright.stop = AsyncMock()
            manager._open[key] = ManagedBrowser(stale_playwright, stale_context)

            new_context = Mock()
            new_playwright = Mock()
            new_playwright.chromium = Mock()
            new_playwright.chromium.launch_persistent_context = AsyncMock(
                return_value=new_context
            )
            starter = Mock()
            starter.start = AsyncMock(return_value=new_playwright)

            with patch("playwright.async_api.async_playwright", return_value=starter):
                reopened = await manager.open(*key, headless=False)

            self.assertIs(reopened, new_context)
            stale_context.close.assert_awaited_once()
            stale_playwright.stop.assert_awaited_once()
            new_playwright.chromium.launch_persistent_context.assert_awaited_once()
            self.assertIs(manager._open[key].context, new_context)

    async def test_open_reuses_live_context_without_relaunch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifacts = ArtifactStore(Path(temporary) / "data")
            manager = BrowserSessionManager(artifacts, browser_channel="chrome")
            key = ("tenant-a", "doubao", "manual")

            live_context = Mock()
            live_context.cookies = AsyncMock(return_value=[])
            live_playwright = Mock()
            manager._open[key] = ManagedBrowser(live_playwright, live_context)

            reopened = await manager.open(*key, headless=False)

            self.assertIs(reopened, live_context)
            live_context.cookies.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
