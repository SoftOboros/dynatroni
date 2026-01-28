"""
Dynatroni DynamoDB DCS Backend

A DynamoDB-based Distributed Configuration Store for Patroni PostgreSQL HA.

This module implements the Patroni AbstractDCS interface using AWS DynamoDB,
providing leader election and cluster state management without requiring
separate consensus services (etcd, Consul, etc.).

Key benefits:
- No quorum requirement: single surviving node can operate
- AWS-native: uses IAM for authentication, fully managed
- Cost-effective: pay-per-request pricing for small clusters
- Highly available: DynamoDB's built-in replication

Table Schema:
- Partition Key: cluster_name (String)
- Sort Key: key (String)
- Attributes: value (String/JSON), session (String), version (Number), ttl (Number)

License: MIT
"""

from .dynamodb import DynamoDB

__all__ = ["DynamoDB"]
__version__ = "0.1.0"
