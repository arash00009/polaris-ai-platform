"""Polaris AI service."""

from importlib.metadata import PackageNotFoundError, version

try:
    __version__ = version("polaris-ai-service")
except PackageNotFoundError:  # running from a source tree that was not installed
    __version__ = "0.0.0+unknown"
