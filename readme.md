# tmg-cityhall

> City hall services: buying identity documents and licences, applying for civilian jobs, and requesting driving lessons from a registered instructor.

## Overview

`tmg-cityhall` places two interactive peds in the world — a city hall clerk and a driving school
instructor — and drives everything through `tmg-menu`. The clerk opens a two-branch menu: **ID
Card**, which lists the licences buyable at the nearest hall, and **Job Center**, which lists every
job registered as publicly hireable. The driving school ped does not open a menu at all; touching it
files a lesson request.

Licence purchasing is a two-stage flow. The client asks
`tmg-cityhall:server:getIdentityData` for the licence list, passing the index of the nearest hall.
The server filters `Config.Cityhalls[hallId].licenses` down to what the player is *eligible* for: an
entry with a `metadata` key (`driver`, `weapon`) is only offered when the corresponding flag is set
in the player's `metadata.licences` table. Picking one fires
`tmg-cityhall:server:requestId`, which **re-applies that same eligibility gate**, re-validates the
hall index against server-side config, measures the player's real distance to that hall's
coordinates, charges cash, and only then issues the item with identity metadata attached.

The driving school side is a licence *permission*, not a licence item. A player standing at the
school fires `tmg-cityhall:server:sendDriverTest`, which logs a `driving_requests` document and
mails every configured instructor — online instructors receive an in-game phone email, offline ones
get an offline mail through `tmg-phone`. When an instructor is satisfied the student can drive, they
run `/drivinglicense <id>`, which sets `metadata.licences.driver = true` on the student. The student
must then go to a city hall and actually buy the `driver_license` item, at which point the
eligibility gate above passes.

Job applications go through `tmg-cityhall:server:ApplyJob`, which checks the requested job is in the
server's own `availableJobs` table and that the player is within 20 units of *some* configured hall
before calling `SetJob`.

## Dependencies

| Resource | Required | Used for |
| :--- | :--- | :--- |
| `tmg-core` | Yes | Player object, `CreateCallback`, `Commands.Add`, `Notify`, `SetJob`, `SetMetaData`, `Shared.Jobs`, `Shared.StarterItems`, `Shared.Items`, `DrawText`/`HideText`/`KeyPressed` |
| `tmgnosql` | Yes | `driving_requests` persistence |
| `tmg-inventory` | Yes | `AddItem` for licences and starter items, `tmg-inventory:client:ItemBox` feedback |
| `tmg-menu` | Yes | Every menu screen |
| `tmg-phone` | Yes | `sendNewMailToOffline` export and the `tmg-phone:server:sendNewMail` event for lesson requests |
| `PolyZone` | Yes | `BoxZone` interaction zones when `Config.UseTarget` is off |
| `tmg-target` | Only when `Config.UseTarget` | `AddTargetEntity` options on the two peds |

No dependency is guarded with `GetResourceState`.

## Configuration

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `Config.UseTarget` | `boolean` | `GetConvar('UseTarget','false') == 'true'` | Switches ped interaction between `tmg-target` options and PolyZone `[E]` prompts |
| `Config.AvailableJobs` | `table<jobName, { label, isManaged }>` | `trucker`, `taxi`, `tow`, `reporter`, `garbage`, `bus`, `hotdog` | Jobs offered in the Job Center. Copied into a server-side `availableJobs` table at load and extended at runtime by the `AddCityJob` export |
| `Config.Cityhalls` | `table[]` | one entry | Per-hall `coords`, `showBlip`, `blipData` and `licenses` |
| `Config.Cityhalls[i].licenses` | `table<itemName, { label, cost, metadata? }>` | `id_card` ($50), `driver_license` ($50, `metadata = 'driver'`), `weaponlicense` ($50, `metadata = 'weapon'`) | Purchasable documents. `metadata` names the flag in `metadata.licences` that must be set before the licence is offered or issued |
| `Config.DrivingSchools` | `table[]` | one entry | Per-school `coords`, `showBlip`, `blipData` and `instructors` |
| `Config.DrivingSchools[i].instructors` | `string[]` | `DJD56142`, `DXT09752`, `SRI85140` | Citizenids authorised to run `/drivinglicense` and eligible to be mailed lesson requests. **These are example values and should be replaced with the real instructors' citizenids** |
| `Config.Peds` | `table[]` | two entries | `model`, `coords` (vec4), `scenario`, a `cityhall` or `drivingschool` flag, and `zoneOptions` (`length`, `width`, `debugPoly`) used when targeting is off |

The `isManaged` field on `Config.AvailableJobs` entries is stored but is not read anywhere in this
resource.

## Exports

### Server

```lua
exports['tmg-cityhall']:AddCityJob(jobName, toCH)
```
| Param | Type | Description |
| :--- | :--- | :--- |
| `jobName` | `string` | Job key, expected to exist in `TMGCore.Shared.Jobs` |
| `toCH` | `table` | `{ label = string, isManaged = boolean }` |

**Returns:** `boolean, string` — `false, 'already added'` if the job is already listed, otherwise
`true, 'success'`.

This mutates the in-memory `availableJobs` table only. It is **not persisted**, so a registering
resource must re-register after every restart. Nothing in this repository currently calls it.

There are no client exports.

## Events

### Server events (client → server)

#### `tmg-cityhall:server:requestId`
Charges for and issues a licence item. **Params:** `(item, hall)`.
**Validation, in order:**
1. `hall` is coerced with `tonumber` and looked up in `Config.Cityhalls`; an unknown index aborts.
2. `item` must be a key of that hall's `licenses` table; an unknown item aborts.
3. The caller's ped must be within **20.0 units** of `hallConfig.coords` — the coordinates the
   *server* holds, not anything the client sent.
4. If the licence declares `metadata`, the caller's `metadata.licences[<flag>]` must be truthy.
   This repeats the filter `getIdentityData` applied, so skipping the menu does not skip the gate.
5. `RemoveMoney('cash', itemInfo.cost, ...)` must succeed.
6. `item` must be one of `id_card`, `driver_license`, `weaponlicense` to build its identity info;
   anything else returns without issuing.

#### `tmg-cityhall:server:ApplyJob`
Sets the caller's job. **Params:** `(job, _cityhallCoords)`.
**Validation:** the caller's ped must be within **20.0 units** of at least one
`Config.Cityhalls[i].coords`, and `job` must be a key of the server's `availableJobs` table. The
second parameter is accepted for call compatibility and is deliberately ignored — the distance is
measured against server-side config.

#### `tmg-cityhall:server:sendDriverTest`
Files a driving lesson request. **Params:** `(instructors)` — an array of citizenids.
**Validation:** the parameter must be a table. Each citizenid is then checked with
`IsDrivingInstructor` against `Config.DrivingSchools`; entries that are not configured instructors
are logged and skipped, so a crafted call cannot mail arbitrary players. The
`driving_requests` document is written from the **caller's** server-side player data regardless.

#### `tmg-cityhall:server:getIDs`
Hands out `TMGCore.Shared.StarterItems`. **Params:** none.
**Validation:** none beyond the player being loaded. Any client may trigger this at any time from
anywhere — see [Security & reliability notes](#security--reliability-notes).

### Client events (server → client, and menu navigation)

| Event | Purpose |
| :--- | :--- |
| `tmg-cityhall:client:sendDriverEmail` | Server → an online instructor. **Params:** `(charinfo)` — the student's charinfo. After a 2.5–4s delay, sends the instructor a phone mail |
| `tmg-cityhall:client:openCityhallMenu` | Reopens the root menu (menu "Go Back" entries) |
| `tmg-cityhall:client:openIdentityMenu` | Opens the licence list |
| `tmg-cityhall:client:openJobMenu` | Opens the Job Center list |
| `tmg-cityhall:client:requestId` | Menu pick handler. **Params:** `{ type, cost }` |
| `tmg-cityhall:client:applyJob` | Menu pick handler. **Params:** `{ job }` |
| `tmg-cityhall:client:getIds` | Asks the server for the starter item set. Nothing in this repository triggers it |

The client also listens to `TMGCore:Client:OnPlayerLoaded`, `TMGCore:Client:OnPlayerUnload` and
`TMGCore:Player:SetPlayerData`; the server listens to `TMGCore:Client:UpdateObject` to refresh its
cached core object.

## Callbacks

### `tmg-cityhall:server:receiveJobs`
`TMGCore.Functions.TriggerCallback('tmg-cityhall:server:receiveJobs', cb)` — returns the whole
`availableJobs` table. No player checks.

### `tmg-cityhall:server:getIdentityData`
`TMGCore.Functions.TriggerCallback('tmg-cityhall:server:getIdentityData', cb, hallId)` — returns a
table of `licenseName → { label, cost, metadata? }`. `hallId` is coerced with `tonumber` and
validated against `Config.Cityhalls`; an invalid index returns `{}` rather than erroring the
callback. Entries carrying a `metadata` key are filtered out unless the corresponding flag is set in
the caller's `metadata.licences`.

## Commands

| Command | Args | Permission | Description |
| :--- | :--- | :--- | :--- |
| `/drivinglicense` | `[id]` | None declared — open to every player | Marks the target as having passed the driving test by setting `metadata.licences.driver = true`. Authorisation is not an ace permission: the handler only performs the write if the **caller's citizenid** appears in a `Config.DrivingSchools[i].instructors` list. Refuses if the target already has the flag, and notifies if the target is not online |

## Items

Issued through `exports['tmg-inventory']:AddItem`:

| Item | When | Attached `info` |
| :--- | :--- | :--- |
| `id_card` | Bought at a hall, or in the starter set | `citizenid`, `firstname`, `lastname`, `birthdate`, `gender`, `nationality` |
| `driver_license` | Bought at a hall (requires `licences.driver`), or in the starter set | `firstname`, `lastname`, `birthdate`, `type = 'Class C Driver License'` |
| `weaponlicense` | Bought at a hall (requires `licences.weapon`) | `firstname`, `lastname`, `birthdate` |
| `TMGCore.Shared.StarterItems` | `tmg-cityhall:server:getIDs` | Currently `phone`, `id_card`, `driver_license` |

## Data model

### `driving_requests`
One document inserted per lesson request by `tmg-cityhall:server:sendDriverTest`. The resource only
ever writes to this collection — nothing in it reads the requests back.

```jsonc
{
  "student_cid": "ABC12345",        // caller's citizenid, taken server-side
  "student_name": "John Doe",
  "phone": "555-0142",              // charinfo.phone
  "status": "pending",              // written once; never updated
  "timestamp": 1754524800           // os.time()
}
```

The resource also reads (never writes) `Player.PlayerData.metadata.licences`, and writes it back
through `SetMetaData` from the `/drivinglicense` command.

No indexes are declared by this resource.

## Security & reliability notes

**Verified server-side**

- **Licence eligibility is enforced twice.** `getIdentityData` filters the menu, and
  `tmg-cityhall:server:requestId` re-checks `metadata.licences[itemInfo.metadata]` before charging.
  A client that fires `requestId` directly for `driver_license` without the `driver` flag is
  rejected with an "not eligible" notification.
- **The hall index is validated against server config, not trusted.** Both `getIdentityData` and
  `requestId` coerce it with `tonumber` and abort on an index that is not present in
  `Config.Cityhalls`.
- **Proximity is measured server-side against server-held coordinates.** `requestId` uses
  `hallConfig.coords` from the resolved hall; `ApplyJob` iterates `Config.Cityhalls` and ignores the
  coordinates the client passes alongside the job name.
- Payment is taken through `Player.Functions.RemoveMoney`, whose failure aborts issuance, and the
  cost is read from config rather than from the client.
- `ApplyJob` will only set a job that is present in the server's `availableJobs` table.
- `sendDriverTest` re-checks every citizenid in the supplied list against `Config.DrivingSchools`
  before mailing, so the list cannot be used to spam arbitrary players.
- `/drivinglicense` verifies the *caller's* citizenid is a configured instructor before writing to
  the target.

**Trusted from the client / not validated**

- **`tmg-cityhall:server:getIDs` is completely unguarded.** It is a plain net event with no
  distance check, no cooldown and no once-per-character flag, so any client can trigger it
  repeatedly to mint unlimited `phone`, `id_card` and `driver_license` items. Nothing in this
  repository triggers it, but the handler is registered and reachable.
- `giveStarterItems` reads the ambient `source` global rather than taking a parameter, and hands out
  a hardcoded quantity of `1` regardless of the `amount` field on the `StarterItems` entry.
- **The purchase confirmation is optimistic.** `tmg-cityhall:client:requestId` shows
  "You have received your … " immediately after firing the server event, before the server has
  charged the player or confirmed the item was added. A rejected purchase still shows a success
  message, followed by the server's error notification.
- `receiveJobs` performs no player check and returns the full job list to any caller.
- `/drivinglicense` calls `TMGCore.Functions.GetPlayer(source)` and dereferences
  `Player.PlayerData.citizenid` without a nil check.
- The distance thresholds (20.0 units) are considerably wider than the interaction zones, so the
  server-side check is a sanity bound rather than a tight proximity requirement.

## Known limitations

- **`metadata.licences.driver` defaults to `true`** in the framework's default player metadata
  (`licences = { driver = true, business = false, weapon = false }`). New characters are therefore
  already eligible to buy a `driver_license` without ever taking a lesson, and `/drivinglicense`
  reports "this person already has permission" for them. The driving school flow only becomes
  meaningful if that default is changed to `false`.
- **`weaponlicense` has no issuing path.** Its gate flag is `licences.weapon`, which defaults to
  `false`, and no command, event or callback in this resource (or elsewhere in the repository) sets
  it. The licence is configured but effectively unobtainable.
- **`driving_requests` is write-only.** Documents are inserted with `status = 'pending'` and are
  never read, listed or updated — there is no instructor-facing queue.
- The instructor citizenids in `Config.DrivingSchools` are example values, and instructors can only
  be changed by editing config and restarting.
- Only one city hall and one driving school are configured, and `Config.Peds` hardcodes one ped per
  role — adding a second hall to `Config.Cityhalls` does not create a second clerk.
- `tmg-cityhall:client:getIds` is registered but never triggered by anything in the repository.
- `AddCityJob` has no counterpart removal export and does not persist across restarts.
- The instructor email built by `tmg-cityhall:client:sendDriverEmail` reads the gender salutation
  from the **instructor's** own `PlayerData.charinfo.gender` rather than the student's, so the
  greeting can address the wrong person's title.
- `deletePeds` removes the spawned peds on unload but does not remove the `tmg-target` entity
  options or the PolyZone boxes registered for them.
- Several locale keys are defined but unused: `success.recived_license`, `info.new_job_app`,
  `info.bilp_text`, `info.city_services_menu`, `info.id_card`, `info.driver_license`,
  `info.weaponlicense`, and the whole `email.jobApp*` set. The menu headers ("City Hall", "ID Card",
  "Job Center", "Identity") and the licence success notification are hardcoded English rather than
  localised.
