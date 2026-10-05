# Netboot, Identity and Fingerprint: full redevelopment scope

## Accepted architecture boundary (2026-10-04)

The user initially confirmed architecture restoration only; the subsequent
UI source-only transfer is recorded in `ui-source-migration.md`, with no runtime
or backend redevelopment. Worker
runtime failures are acceptable. Network services execute on Worker and their
configuration is authored in Management. Netboot and Identity belong exclusively
to Worker: no Management provisioning server or central identity/trust authority.
The functional inventory below is future redevelopment work, not an architecture
completion gate or authorization to implement it now.

Checked 2026-10-02 on dirty `main`, baseline `d83442c0`. Historical references
below mean `git show 8550aa05:<path>`, not the simplified current Console source.
This document corrects the functional inventory; it is not implementation or
runtime acceptance. Original-function redevelopment remains a separate future scope.

## Netboot

### Complete profile authoring, not the later four-field form

Sources: historical `apps/yellow_dog_console/lib/yellow_dog/console/live/netboot_live/profile_editor_live.ex`
and `netboot_live/profiles_live.ex`.

Required editor fields:

- Stable lowercase profile ID, immutable while editing; description.
- Separate required kernel and initrd paths; kernel arguments as a string.
- Optional installer image.
- Architectures: `x86_64`, `aarch64`, `bios_x86`; no selection means Any.
- Manifest settings: disk layout (`single-root-btrfs`, `single-root-ext4`,
  `zfs-mirror`), slot strategy (`single`, `ab`), flake reference.

Required functions are create/edit/clone, inline validation, cancellation,
confirmed deletion and live iPXE text preview; ID/description/kernel/initrd
search, sorting, architecture display, filtered CSV and Set Default. Cloning
prefills content but requires a new identity. Kernel/initrd file-index suggestions
and missing-file warnings are also original functions; warnings do not block saving.
Actual device usage counts and assigned-device warnings need a genuine source.

The current legacy `profile_id/name/boot_asset_id/arguments` editor omits these
fields; its CSV handler is a no-op and default selection is unavailable. Neither
that editor nor a matching new four-field PG form establishes original parity.
Manifest backend fields such as post-install hooks do not prove an original hooks
editor; do not invent one or silently erase retained manifest content.

Historical default selection uses `persistent_term`, without durable existence
checks. Native default intent needs a same-scope reference and a defined safe
deletion rule; preserve default selection, not dangling-default behavior.

**Accepted service ownership:** Netboot is Worker-only; Management authors its
configuration without executing it. Profile reuse/default configuration modelling
is deferred and does not block architecture restoration. Do not invent a global
runtime default, a Management Netboot Service or runtime success from a saved draft.

After that choice, a complete native desired-authoring workflow is meaningful
independent work. Scope paths, original-revision CAS, durable defaults,
full-field reopen/clone fidelity, pure preview and unchanged Worker targets are
required evidence. File availability remains unknown until an actual artifact
source exists; usage is unknown, not an invented zero. This alone does not
complete provisioning or boot execution.

### Device, artifact and provisioning functions remain required

- Devices: actual discovery; search/state/profile filters, sorting and CSV;
  selected/bulk profile assignment, tags and deletion; identity, installation
  attempts/errors/state history, reinstall/rescue controls and script preview.
- TFTP/files: the executing node's file tree, relative-target upload/cancel,
  deletion and rescan; file inventory and actual transfer statistics/history,
  filtering/sorting/CSV. Existing Management backup/task artifacts are not
  automatically published boot assets.
- Logs: real boot/device/TFTP events, search/type/severity filters, pause/resume,
  view-only clear and filtered CSV; device state history and transfer history
  are not Management mutation audit.
- Installer HTTP: registration, assigned/default profile resolution, iPXE
  generation, asset/manifest serving and actual installation-status callbacks.

Sources: historical `netboot_live/devices_live.ex`, `device_detail_live.ex`,
`tftp_live.ex`, `log_live.ex`, and
`apps/yellow_dog_console/lib/yellow_dog/console/controllers/boot_controller.ex`.
These need artifact/execution/observation ownership, not invented PG observations.

## Identity

Sources: historical `apps/yellow_dog_console/lib/yellow_dog/console/live/identity/`
and `controllers/identity_controller.ex`; backend models under
`apps/yellow_dog_identity/lib/yellow_dog_identity/`.

The later read-only token listing is not complete original functionality:

- Create tokens using hostname pattern, max uses, TTL hours and optional role.
  Show the secret once, dismiss it, list and revoke. Retain hashed storage,
  hostname matching, expiry/revocation checks and atomic usage consumption.
- Enroll actual host identities with hostname, machine ID, SSH public key,
  derived key fingerprint, age recipient, role/datacenter/metadata and request
  provenance. Validation, duplicate handling, attestation and trust/policy
  evaluation are business operations, not logical Worker registration.
- Host list/detail: status/hostname filtering, refresh, keys/previous keys,
  trust details, approval/revocation provenance and host audit.
- Individual and selected-batch approval/rejection; approval requires pending.
  Historical rejection revokes with a reason, rather than introducing a separate
  rejected state. Preserve explicit actor/time/reason and trustworthy state.
- Policies are read-only ordered name/description/match/action/default-action
  data; first matching policy wins. Do not infer policy CRUD from backend types.
- Identity audit is actual enrollment/trust/credential history with event/host
  filters, not interchangeable with general Management mutation audit.

**Accepted authority boundary:** Identity belongs exclusively to Worker, including
enrollment, trust and credential execution. The earlier Management/PostgreSQL
central-authority proposal is superseded. Management may author configuration,
but its logical rows or UI actor labels are not identity/trust authority or
authenticated operator evidence. No credential implementation is in this task.

The existing generic Domain audit/idempotency gateway stores returned results.
A token implementation must not feed a raw secret into those durable results.
This is a future integration invariant, not a claim that a native token leak
already exists. Issuing credential-looking drafts without genuine consumption,
or labelling rows approved without settled trust authority, is not parity.

## Fingerprint

Source: historical
`apps/yellow_dog_console/lib/yellow_dog/console/live/fingerprint_live/fingerprints_live.ex`.

Required functions include known/unknown tabs, parameter/vendor/profile search,
filtered CSV, a classification modal selecting an existing profile with an
optional note, cancellation and `save_override(hash, profile_id, note)`.
The displayed signatures include DHCP family/ordered parameters/vendor class,
classification/confidence, hits and observation timestamps. Device pages add
observed MAC/IP/DUID, profile confidence and first/last seen.

This is not merely a fingerprint-database inspection page. However, the
module documentation's claims about class creation and bulk classification do
not establish corresponding form/handler behavior: do not invent those editors.
Profiles come from configured data, not a proven pure built-in catalogue.

Native classification still needs an actual signature/observation source,
scope/provenance, and a decision about whether an override affects Management
classification or Worker execution. Do not create synthetic unknown fingerprints,
manual signature-entry/profile CRUD or false hit counts to populate the UI.

## Implementation boundary

The service ownership is settled; full provisioning, Identity/Fingerprint workflows
and DNS shared-contract expansion remain future functional work. Do not implement
them merely to finish architecture restoration. Documentation or future PG CRUD
does not satisfy the missing runtime functions, but those functions are not gates
for the current architecture-only deliverable.

No source/runtime/schema/credential changes or feature acceptance are claimed
by this audit. No unrelated tests were run and no compatibility layer is proposed.
