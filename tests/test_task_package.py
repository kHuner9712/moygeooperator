import io
import tempfile
import unittest
import zipfile
from pathlib import Path

from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.tasks import DuplicateTaskPackageError, TaskPackageService
from geo_operator.tenants import TenantService
from tests.helpers import build_task_package, make_task


class TaskPackageTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.database = Database(root / "operator.sqlite3")
        self.database.initialize()
        self.artifacts = ArtifactStore(root / "data")
        self.tenant = TenantService(self.database, self.artifacts).create("KZQ")
        self.service = TaskPackageService(self.database, self.artifacts)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_import_persists_tasks_and_requires_approval(self) -> None:
        package = self.service.import_zip(
            self.tenant["id"],
            build_task_package(self.tenant["id"], "kzq-round-1", [make_task(1), make_task(2)]),
        )
        self.assertEqual(package["status"], "WAIT_HUMAN_APPROVAL")
        self.assertEqual(len(package["tasks"]), 2)
        approval = self.database.one(
            "SELECT * FROM approvals WHERE id=?", (package["approval_id"],)
        )
        self.assertEqual(approval["stage"], "TASK_EXECUTION")
        with self.assertRaises(DuplicateTaskPackageError):
            self.service.import_zip(
                self.tenant["id"],
                build_task_package(self.tenant["id"], "kzq-round-1", [make_task(1), make_task(2)]),
            )

    def test_hash_and_tenant_mismatch_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.service.import_zip(
                self.tenant["id"],
                build_task_package(
                    self.tenant["id"], "bad-hash", [make_task(1)], tasks_hash="0" * 64
                ),
            )
        with self.assertRaisesRegex(ValueError, "tenant_id"):
            self.service.import_zip(
                self.tenant["id"],
                build_task_package("another-tenant", "wrong-tenant", [make_task(1)]),
            )

    def test_zip_path_traversal_is_rejected(self) -> None:
        valid = build_task_package(self.tenant["id"], "unsafe", [make_task(1)])
        source = zipfile.ZipFile(io.BytesIO(valid))
        output = io.BytesIO()
        with source, zipfile.ZipFile(output, "w") as archive:
            for info in source.infolist():
                archive.writestr(info.filename, source.read(info.filename))
            archive.writestr("../escape.txt", "bad")
        with self.assertRaisesRegex(ValueError, "Unsafe path"):
            self.service.import_zip(self.tenant["id"], output.getvalue())


    def test_unsafe_account_id_is_rejected(self) -> None:
        task = make_task(1)
        task["account_id"] = "../../escape"
        with self.assertRaisesRegex(ValueError, "Invalid account_id"):
            self.service.import_zip(
                self.tenant["id"],
                build_task_package(self.tenant["id"], "unsafe-account", [task]),
            )


if __name__ == "__main__":
    unittest.main()
