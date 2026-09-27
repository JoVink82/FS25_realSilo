# RealSilo – Realistic Silo Compartments

RealSilo divides your farm silos into separate compartments, each holding
one type of product, instead of mixing everything into one large tank. You
decide how many compartments a silo gets and how much each one can hold.

![Compartment overview](screenshots/compartment-overview.jpg)

## Features

- Split any farm silo into 1–32 independent compartments, each with its own
  crop and capacity.
- Only the active compartment receives or unloads grain — no more mixing.
- Transfer grain between compartments at an adjustable speed.
- Silo extensions are supported and show up as extra compartments in the
  same menu.
- Grain that was already in a silo before RealSilo was installed is kept
  and distributed across compartments the first time you configure it.
- In multiplayer, only the farm admin can change silo settings; every
  player can use the silo normally and view the compartment overview.
- Full compatibility with [FS25_MoistureSystem](https://github.com/Ozz-Modding/FS25_MoistureSystem):
  moisture and quality are tracked independently per compartment, including
  drying, and this now also works correctly for every player on a dedicated
  server, not just the host.

![Silo info overlay](screenshots/silo-infobox.jpg)

## How it works

1. Walk up to an existing silo or place a new one and press the RealSilo
   key (default **K**, changeable under Options > Controls) to open the
   configuration dialog. In multiplayer, only the admin can do this.
2. Choose how many compartments the silo should have and how much each one
   can hold.
3. Select the active compartment from the overview — only that compartment
   receives or unloads grain until you pick a different one.
4. Use the Transfer function to move grain between compartments at your own
   pace.

![Grain Drying menu](screenshots/grain-drying-menu.jpg)

## Drying control

If [FS25_MoistureSystem](https://github.com/Ozz-Modding/FS25_MoistureSystem)
is installed, RealSilo adds drying controls of its own, right inside the
silo menu — no need to dig through the base game's Shift+M menu just to
find your compartments.

- **Per-silo dryer switch.** Each silo has its own "Dryer available"
  toggle on the Settings page. Switch it off for a silo that doesn't have
  a dryer, and its compartments won't show up in the Grain Drying menu at
  all.

  ![Dryer toggle in Settings](screenshots/settings-dryer-toggle.jpg)

- **A dedicated Drying page.** From the compartment overview, press **D**
  or click the **Drying** button in the footer to open a page listing every
  filled compartment for that silo, with its moisture percentage, quality
  grade, and whether it's currently drying.

  ![Drying button on the overview page](screenshots/overview-drying-button.jpg)

- **One click, no save step.** Click a compartment on the Drying page to
  switch its drying on or off immediately — just like toggles work in the
  base game's own menus.

  ![Drying page with per-compartment status](screenshots/drying-page.jpg)

- Number fields such as Speed and Extension search range use simple
  left/right selectors, the same style as the base game's own settings.

## Installation

1. Download `FS25_RealSilo.zip` from the [Releases](../../releases) page
   (or from the [Giants ModHub](https://www.farming-simulator.com/mods)).
2. Drop the zip into your FS25 `mods` folder — do **not** unzip it.
3. Enable it in the in-game mod selection when starting or hosting a
   savegame.

## For modders

Building a silo mod of your own and want it to integrate with RealSilo out
of the box (automatic compartment layout, no manual player configuration
needed)? See [`README_modders.md`](README_modders.md) for the full
`<realSilo>` / `<realSiloExtension>` XML reference.

## Compatibility

- **[FS25_MoistureSystem](https://github.com/Ozz-Modding/FS25_MoistureSystem):**
  fully supported. Each compartment dries independently and appears as its
  own entry in the Grain Drying menu (Shift+M), for every player — host or
  client, singleplayer or dedicated server. RealSilo's own Drying page (see
  above) gives a per-silo shortcut to the same information.

## Reporting problems

Found a bug or have a suggestion? Please open an issue on GitHub:
https://github.com/JoVink82/FS25_realSilo/issues

## Author

Jo_Vink
