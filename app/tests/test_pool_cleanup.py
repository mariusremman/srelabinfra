import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import main


class FakeCursor:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def execute(self, query, parameters):
        self.query = query
        self.parameters = parameters

    def fetchone(self):
        return (1,)


class FakeConnection:
    def __init__(self):
        self.cursor_instance = FakeCursor()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def cursor(self):
        return self.cursor_instance


class FakePool:
    def __init__(self, connection):
        self.connection = connection
        self.returned_connections = []

    def getconn(self):
        return self.connection

    def putconn(self, connection):
        self.returned_connections.append(connection)


class EnsureNameAvailableTests(unittest.TestCase):
    def setUp(self):
        self.original_pool = main.pool
        self.connection = FakeConnection()
        self.pool = FakePool(self.connection)
        main.pool = self.pool

    def tearDown(self):
        main.pool = self.original_pool

    def test_duplicate_name_returns_connection_to_pool(self):
        with self.assertRaises(main.HTTPException) as error:
            main.ensure_name_available("duplicate")

        self.assertEqual(error.exception.status_code, 409)
        self.assertEqual(self.pool.returned_connections, [self.connection])


if __name__ == "__main__":
    unittest.main()
