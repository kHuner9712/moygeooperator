import asyncio

from geo_operator.browser import ExecutionStateMachine
from geo_operator.browser.lease import ExecutionLeaseManager
from geo_operator.browser.registry import PluginRegistry
from geo_operator.browser.session import BrowserSessionManager
from geo_operator.browser.supervisor import WorkerSupervisor
from geo_operator.browser.worker import WorkerConfig
from geo_operator.core.config import Settings
from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.results import ResultService


def main() -> None:
    settings = Settings.from_env()
    database = Database(settings.database_path)
    database.initialize()
    artifacts = ArtifactStore(settings.data_root, database)
    sessions = BrowserSessionManager(artifacts, database, browser_channel=settings.browser_channel)
    supervisor = WorkerSupervisor(
        database,
        sessions,
        ExecutionStateMachine(database),
        ExecutionLeaseManager(database),
        ResultService(database, artifacts),
        PluginRegistry(database, f"http://{settings.host}:{settings.port}"),
        WorkerConfig(
            headless=False,
            action_delay_min=settings.browser_action_delay_min,
            action_delay_max=settings.browser_action_delay_max,
        ),
    )
    asyncio.run(supervisor.run_forever())


if __name__ == "__main__":
    main()
