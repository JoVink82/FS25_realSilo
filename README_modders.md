# realSilo — Modder Integration Guide

This document explains how to integrate your placeable silos and silo extensions
with the **realSilo** mod, which adds compartment-based storage management to
Farming Simulator 25.

---

## Table of Contents

1. [How it works](#how-it-works)
2. [Silo configuration](#silo-configuration)
3. [Extension configuration](#extension-configuration)
4. [Full examples](#full-examples)
5. [Rules and limits](#rules-and-limits)

---

## How it works

realSilo reads optional `<realSilo>` and `<realSiloExtension>` tags from your
placeable XML files. If these tags are present, the silo or extension is
automatically configured when placed — no in-game setup required by the player.

If the tags are absent, realSilo still works: the player can configure the
silo manually via the in-game dialog (press **R** near the silo).

---

## Silo configuration

Add a `<realSilo>` tag directly inside `<placeable>`, **after** the `</silo>` closing tag.

### Attributes

| Attribute | Required | Type | Description |
|---|---|---|---|
| `compartments` | Yes | integer | Number of compartments (1–32) |
| `name` | No | string | Display name shown in the dialog |
| `locked` | No | boolean | Defaults to `true` when `<realSilo>` is present. Set `locked="false"` to let players reconfigure compartments/capacity in-game. |
| `transferRate` | No | integer | Internal transfer speed in L/min (default: 1000) |

### Child elements — `<compartment>`

Each `<compartment>` sets the capacity of one specific compartment.
You do not need to define all compartments — only the ones you want to
override. The remaining compartments use the default capacity calculated
from the silo's total storage capacity divided by the number of compartments.

| Attribute | Required | Type | Description |
|---|---|---|---|
| `index` | No | integer | Compartment number (1-based). If omitted, order in XML is used. |
| `capacity` | Yes | integer | Capacity in litres (minimum 1000) |

### Example — uniform compartments

```xml
<placeable>
    ...
    <silo>
        ...
    </silo>

    <realSilo compartments="4" name="Your-mod" transferRate="2000">
    </realSilo>
</placeable>
```

### Example — custom capacity per compartment

```xml
<realSilo compartments="4" name="Your-mod">
    <compartment index="1" capacity="100000" />
    <compartment index="2" capacity="75000" />
    <compartment index="3" capacity="25000" />
    <compartment index="4" capacity="20000" />
</realSilo>
```

### Example — locked configuration (set by mod, not editable by player)

```xml
<realSilo compartments="2" name="Your-mod" locked="true">
    <compartment index="1" capacity="150000" />
    <compartment index="2" capacity="150000" />
</realSilo>
```

---

## Extension configuration

Add a `<realSiloExtension>` tag directly inside `<placeable>`, **after** the
`</siloExtension>` closing tag.

An extension can add **one or more compartments** to the nearest silo.
Each `<compartment>` child element creates one compartment with its own capacity.

### Child elements — `<compartment>`

| Attribute | Required | Type | Description |
|---|---|---|---|
| `index` | No | integer | Compartment order (1-based). If omitted, order in XML is used. |
| `capacity` | Yes | integer | Capacity in litres (minimum 1000) |

> **Note:** An extension uses a single physical storage node from Giants.
> realSilo manages the split into multiple virtual compartments internally.
> Fill levels per compartment are saved and restored correctly across sessions.

### Example — single compartment extension

```xml
<placeable>
    ...
    <siloExtension>
        <storage node="storage" fillTypeCategories="farmSilo" capacity="220000" isExtension="true"/>
    </siloExtension>

    <realSiloExtension>
        <compartment capacity="220000" />
    </realSiloExtension>
</placeable>
```

### Example — multiple compartments with individual capacity

```xml
<realSiloExtension>
    <compartment index="1" capacity="100000" />
    <compartment index="2" capacity="75000" />
    <compartment index="3" capacity="45000" />
</realSiloExtension>
```

### Example — using index to control order

```xml
<realSiloExtension>
    <compartment index="2" capacity="50000" />
    <compartment index="1" capacity="120000" />
</realSiloExtension>
```

The compartments are always sorted by `index` before being linked to the silo,
so the above results in: compartment 1 = 120.000 L, compartment 2 = 50.000 L.

---

## Full examples

### Your-mod Silo (Your-mod.xml`)

```xml
<silo>
    <loadingStation node="loadingTrigger" supportsExtension="true" storageRadius="50">
        ...
    </loadingStation>
    <unloadingStation supportsExtension="true" storageRadius="50">
        ...
    </unloadingStation>
    <storages>
        <storage node="storage" fillTypeCategories="farmSilo" capacity="220000" isExtension="true"/>
    </storages>
</silo>

<realSilo compartments="4" name="Your-mod">
    <compartment index="1" capacity="100000" />
    <compartment index="2" capacity="60000" />
    <compartment index="3" capacity="40000" />
    <compartment index="4" capacity="20000" />
</realSilo>
```

### Your-mod Extension (`Your-mod_Extension.xml`)

```xml
<siloExtension>
    <storage node="storage" fillTypeCategories="farmSilo" capacity="220000" isExtension="true"/>
</siloExtension>

<realSiloExtension>
    <compartment index="1" capacity="110000" />
    <compartment index="2" capacity="110000" />
</realSiloExtension>
```

---

## Rules and limits

- **Compartment count:** 1 to 32 per silo. Extensions can add any number of
  additional compartments.
- **Minimum capacity:** 1000 L per compartment. Values below this are clamped
  to 1000 L automatically.
- **Total capacity:** The sum of all compartment capacities does not need to
  match the Giants `capacity` attribute on the `<storage>` node. realSilo
  manages its own capacity tracking.
- **Index:** Must be a positive integer starting at 1. Gaps are allowed
  (e.g. index 1, 3, 5). Compartments are always sorted by index before
  being applied.
- **Locked silos:** As soon as a `<realSilo>` tag is present, the silo's
  configuration is **locked by default** — players cannot open the settings
  dialog or edit individual compartment capacities, since the layout is
  already defined by you. Add `locked="false"` to the `<realSilo>` tag if you
  want players to be able to reconfigure the silo themselves.
- **Locked extensions:** Likewise, any compartment defined via
  `<realSiloExtension>` is shown as fixed ("🔒 vast door mod") in the
  Extensions dialog and cannot be edited by the player. If an extension has
  **no** `<realSiloExtension>` tag at all, its compartment(s) remain fully
  editable by the player, exactly as before.
- **Extension linking:** Extensions are automatically linked to the nearest
  realSilo within 50 metres. Make sure only one realSilo placeable is within
  that radius, or the extension may link to the wrong silo.
- **Compatibility:** The `<realSilo>` and `<realSiloExtension>` tags are
  ignored by the base game and by other mods, so adding them does not break
  anything if realSilo is not installed.

