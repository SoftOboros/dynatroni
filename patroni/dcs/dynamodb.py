"""Expose Dynatroni to Patroni's module-based DCS discovery."""

from dynatroni.dynamodb import DynamoDB

__all__ = ["DynamoDB"]
