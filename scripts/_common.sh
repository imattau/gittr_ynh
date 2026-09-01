#!/bin/bash

# Pinned versions — bump deliberately, verify against upstream before changing.
GO_VERSION="1.21.6"
NODEJS_VERSION=20

# Pin upstream to a known-good ref rather than tracking a moving `main`.
# TODO: verify this ref still exists / is still the intended target before
# any real install runs against it.
GITTR_REF="main"
