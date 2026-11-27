# Legacy File Handle Lease — Security Boundaries

Status: experimental, read-only prototype. This document describes the implementation at the current recovery-branch revision; it is not an approval to execute cleanup.

## What the prototype currently enforces

- Opens each directory component in the installation-root chain and candidate-parent chain with directory semantics and `FILE_FLAG_OPEN_REPARSE_POINT`.
- Rejects directory components that are reparse points or do not resolve to the expected canonical path (the volume root is handled separately because Windows may return a volume-GUID path).
- Holds directory handles without write/delete sharing for the lifetime of the lease. Ordinary Win32 rename, removal, and replacement attempts against those pinned entries should therefore fail while the lease is open.
- Opens the candidate file with `FILE_FLAG_OPEN_REPARSE_POINT` and share mode zero. Existing incompatible handles cause the open to fail; new ordinary opens that request sharing-incompatible access are denied while the lease is held.
- Rejects directories, reparse-point candidates, files whose final handle path is outside the final installation-root path, and files with more than one hard link.
- Computes SHA-256 through the same opened file handle used to obtain file identity. It checks identity, link count, length, last-write timestamp, and stream length again after hashing.
- Exposes read-only status and explicitly reports that execution is not authorized. It contains no delete, rename, registry mutation, or install operation.

## Audit reparse-point coverage

- The legacy installation audit rejects an install or data root that is itself a reparse point and reports it as `ReparsePointPreserved`.
- The audit reports nested reparse-point directories and does not intentionally descend through them; Windows CI tests cover root and nested directory junctions for both install and data trees.
- These tests cover directory junction behavior only. They do not establish equivalent behavior for symbolic links, volume mount points, UNC shares, DFS, cloud-backed placeholders, or third-party filesystem/filter drivers.
- The file-handle lease has separate component-level reparse-point checks, but neither the audit tests nor the lease tests currently establish a universal race-free guarantee for every filesystem or namespace.

## What this does not prove

- It does not prove that a file or COM registration historically belongs to MicBridge. A matching name, path, hash, or CLSID is not ownership evidence.
- The read-only audit now exposes `OwnershipProven = false` and `OwnershipEvidenceStatus = NotEstablished` explicitly. Its classifications are inventory hints only; they must not be consumed as deletion authorization.
- It does not prove that a backup captured the original Windows state. A digest proves integrity relative to the supplied manifest, not historical truth.
- It does not provide an atomic, path-relative unlink/delete operation. Holding a lease is not equivalent to a safe deletion primitive.
- It is not a complete defense against privileged/kernel actors, offline volume modification, filesystem/filter-driver behavior outside ordinary Win32 sharing semantics, or every remote/network filesystem implementation.
- It does not establish that every filesystem supports the same handle-sharing and directory pinning guarantees. Unsupported or incompatible behavior must fail closed.
- The pre/post metadata checks detect several forms of mutation during hashing, but they are not a universal proof against all filesystem races or adversarial storage behavior.

## Required gates before any executor can be considered

1. Independent security review of path resolution and directory-handle ancestry, including mount points, volume roots, UNC paths, case/normalization behavior, and filesystem-specific semantics.
2. Deterministic Windows tests for concurrent ancestor/child rename, replacement, junction insertion, pre-existing incompatible handles, hard links, and cleanup of all handles on every failure path.
3. A deletion design based on a proven path-relative/handle-relative primitive, or a documented decision that deletion cannot be made safe enough and must remain manual.
4. Trusted ownership evidence independent of the audit journal (for example, a separately trusted installer manifest or transaction provenance); shared COM keys remain preserved unless ownership is independently established.
5. Human review and explicit approval bound to the exact item identity, content digest, transaction, and current preflight state.
6. Installer/package integration only after the above gates pass and the complete test suite succeeds.

## Current integration rule

The installer and build package must continue to exclude the cleanup planner, journal, approval-signature, preflight, and file-handle lease prototypes. The installer may run the read-only legacy audit and must stop on any legacy, ambiguous, unreadable, foreign/shared, or otherwise unresolved state. No automatic cleanup is authorized by this prototype.
