import unittest
from unittest.mock import patch

from geo_operator.websites import validate_public_url


class WebsiteUrlValidationTestCase(unittest.TestCase):
    @staticmethod
    def _resolved(*addresses: str) -> list[tuple[None, None, None, None, tuple[str, int]]]:
        return [(None, None, None, None, (address, 443)) for address in addresses]

    def test_proxy_fake_ip_dns_placeholder_is_allowed_for_hostname(self) -> None:
        with patch(
            "geo_operator.websites.service.socket.getaddrinfo",
            return_value=self._resolved("198.18.1.23"),
        ):
            normalized = validate_public_url("https://customer.example/path#section")
        self.assertEqual(normalized, "https://customer.example/path")

    def test_direct_fake_ip_literal_remains_blocked(self) -> None:
        with self.assertRaisesRegex(ValueError, "non-global addresses"):
            validate_public_url("https://198.18.1.23/")

    def test_private_dns_resolution_remains_blocked(self) -> None:
        with patch(
            "geo_operator.websites.service.socket.getaddrinfo",
            return_value=self._resolved("10.0.0.8"),
        ):
            with self.assertRaisesRegex(ValueError, "non-global addresses"):
                validate_public_url("https://internal.example/")

    def test_mixed_fake_ip_and_private_resolution_is_blocked(self) -> None:
        with patch(
            "geo_operator.websites.service.socket.getaddrinfo",
            return_value=self._resolved("198.18.1.23", "192.168.1.10"),
        ):
            with self.assertRaisesRegex(ValueError, "non-global addresses"):
                validate_public_url("https://mixed.example/")


if __name__ == "__main__":
    unittest.main()
