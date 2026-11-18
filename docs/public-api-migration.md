# Public API migration

## Contract

Orca Island uses the documented plugin facade and executable CLI, not Orca implementation modules or profile storage. Minimum supported Orca: **1.4.260**. The native macOS notch UI remains unchanged in shape.

Official references:

- [Plugin authoring and stability](https://github.com/stablyai/orca/blob/main/docs/reference/plugin-authoring.md#stability)
- [Host API, version table and event schemas](https://github.com/stablyai/orca/blob/main/docs/reference/plugin-host-api.md)
- [CLI reference](https://orca.dev/docs/cli/reference)

## Data flow

| Role | Supported interface | Responsibility |
| --- | --- | --- |
| Plugin worker | `agent.status.changed`, workspace events | Low-latency state notifications; bounded ordered relay to localhost |
| Plugin worker | `workspace.list({ includeStatus: true })` | Resolve the event's public `workspaceListId` to a known host and workspace label; unresolved identities are not guessed |
| Swift companion | `environment list --json` | Saved paired-host catalog, including empty/offline hosts |
| Swift companion | `worktree ps`, `terminal list`, `agent list`, JSON output | Startup and periodic authoritative reconciliation, explicitly scoped to each host |
| Swift companion | `terminal switch --terminal <handle> --environment <host>` | User-initiated navigation after a fresh, unique host/workspace/pane match |

The companion invokes the public CLI directly with argument arrays. It strips inherited `ORCA_*` selectors so a desktop-wide read cannot accidentally target the agent's current workspace or remote host. Reads have time, output and concurrency limits. A failed or truncated inventory is unavailable, not an authoritative empty inventory; the last successful rows on that host are retained as stale.

Only fields required to render state and validate navigation are retained. Agent replies, prompts, transcript bodies, credentials and pairing codes are not part of Island's model or diagnostics.

## Identity and clocks

The public event payload is experimental. The relay checks fields, preserves `workspaceListId`, and isolates deduplication by host/workspace/pane instead of assuming raw pane keys are globally unique. Opaque workspace and terminal identifiers are not decoded.

CLI inventories are projected by the source host, workspace and full pane key. Event receipt on this desktop is not a remote machine's state timestamp: remote events request reconciliation rather than overwriting authoritative remote state using an unrelated clock. A polling timestamp alone cannot manufacture a new completed turn.

## Deliberate differences

| Old private dependency | Replacement / limitation |
| --- | --- |
| Orca's per-pane acknowledgement and idle-display preference | Island-owned completed-turn acknowledgements persisted in its own app defaults; separate from Orca's unread state |
| Profile database and viewer mirror mapping | Host-qualified public inventory; no inspection of another app's settings or storage |
| Full retained sleeping/session-tab layout | Best-effort public `agent list`; no claim that this proves every retained pane still exists |
| Private chat/session reveal RPC | No replacement is invented; chat/sleeping cards without a verified live terminal show a navigation-unavailable reason |

`agent.resume` is deliberately not a navigation fallback: it can start a new process and is not equivalent to showing an existing conversation. Public CLI navigation to a paired environment uses this desktop's supported route, not a request to focus the remote machine.

## Regression checks

```sh
node --test tests/*.test.mjs tests/*.test.cjs
./tests/check-public-cli.sh
./tests/check-island-ack.sh
```

CI and release checks also run the existing native geometry, input, animation, completion, synchronization, bridge and HTTP harnesses. Fixtures use anonymous identities, injected executors and isolated acknowledgement storage; they never inspect the user's transcripts or navigate the live desktop.

Pushing these source changes is separate from publishing a versioned companion binary. Existing installed companion applications must be rebuilt/replaced or updated from a later release to use the new native collector.
