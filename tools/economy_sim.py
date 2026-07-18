"""Pacing simulation for the ClickGame economy rebalance.

Models players buying greedily by payback time (cost / production gained) and
validates time-to-unlock for each building tier, the clicking-power curve, and
the autoclick "idle route" (power x speed). Vertical floors are sequential,
one-time purchases whose themed bonuses compete in the same greedy loop.

Profiles:
  - active (3 clicks/s): the engaged player.
  - casual (0.5 clicks/s): light clicking.
  - idle (0 clicks/s): never clicks manually; rides buildings + autoclick. This
    is the route the autoclick lines must keep viable AND supplementary.

Run: python3 tools/economy_sim.py
"""

# Proposed ladder: (name, base_cost, cps). Cost scales 1.15^owned.
# v3: building upgrades (x2 per tier) carry the mid-game compression, so base
# CpS reverts toward Cookie Clicker values; early costs stay cheap so session 1
# reaches Factory.
BUILDINGS = [
    ("Noob Clicker", 15, 0.1),
    ("Granny", 100, 1),
    ("Farm", 800, 8),
    ("Cookie Mine", 9_000, 47),
    ("Cookie Factory", 95_000, 260),
    ("Cookie Bank", 1_400_000, 1_400),
    ("Cookie Distributer", 20_000_000, 9_000),
    # Approved 2026-07-16 late-tier re-tune for expected goo x1.25 plus floors.
    ("Research Facility", 500_000_000, 70_000),
    ("Portal", 8_000_000_000, 450_000),
    ("Time Machine", 120_000_000_000, 3_000_000),
]
GROWTH = 1.15

# Approved 2026-07-16 vertical floors. Every matching building is assumed to be placed on
# its optimal themed floor once that floor is owned. The runtime requirement to
# place buildings physically on that floor is intentionally abstracted away.
FLOORS = [
    {
        "name": "Floor 1 (Industry)",
        "price": 75_000,
        "multiplier": 1.50,
        "buildings": {"Cookie Mine", "Cookie Factory"},
    },
    {
        "name": "Floor 2 (Finance & Distribution)",
        "price": 500_000_000,
        "multiplier": 1.50,
        "buildings": {"Cookie Bank", "Cookie Distributer"},
    },
    {
        "name": "Floor 3 (Science)",
        "price": 100_000_000_000,
        "multiplier": 1.50,
        "buildings": {"Research Facility", "Portal", "Time Machine"},
    },
]

# Building upgrades: per building, 2 levels, each doubles that building's
# output. (owned_threshold, cost = building base_cost * factor)
UPGRADE_TIERS = [(10, 25), (25, 250)]

# Clicking Power: level n (0-indexed) costs 500 * 10^n.
# Total cookies-per-click at level n = 2^n (1, 2, 4, 8, ...).
CLICK_BASE_COST = 500
CLICK_COST_GROWTH = 10
CLICK_RATE = 3.0  # clicks per second, active play

# --- Autoclick "idle route" -------------------------------------------------
# Two INDEPENDENT lines (not synced to click power); income = power x speed.
#   power = cookies per auto-click (long line, escalating cost-per-CpS)
#   speed = auto-clicks per second (short, bounded line; base = 2/s)
# autoclick CpS = AUTO_POWER_VAL[power_level] * AUTO_SPEED_VAL[speed_level].
# Design intent: cheap session-1 entry, then payback grows ~1.67x per power
# level (mirrors the building curve) so it dominates early and FADES to a small
# supplement late. Speed is bounded at x2.5 so power*speed can't run away.
#
# Power: first cost = 550, then cost x10 per level; per-click value = 5^(n-1).
# Level 0 = no clicker.
# cost grows x10/level while output grows x5 -> cost-per-CpS grows x2 per level.
# A short 6-level line: autoclick is the early/early-mid hook + supplement and
# DELIBERATELY tapers late (buildings are the real idle engine; spec §2).
AUTO_POWER_VAL = [0, 1, 5, 25, 125, 625, 3125]
AUTO_POWER_COST = [0, 550, 5_000, 50_000, 500_000, 5_000_000, 50_000_000]
# Speed: clicks/sec per level (level 0 is the free baseline once you own a clicker).
AUTO_SPEED_VAL = [2, 3, 4, 5]
AUTO_SPEED_COST = [0, 25_000, 1_000_000, 50_000_000]

SIM_END_HOURS = 200


def validate_floor_config():
    """Fail fast if the approved config violates the frozen launch constraints."""
    if len(FLOORS) != 3:
        raise ValueError("launch economy must define exactly three floors")

    building_names = {name for name, _, _ in BUILDINGS}
    themed_buildings = set()
    previous_price = 0
    for floor in FLOORS:
        unknown = floor["buildings"] - building_names
        overlap = floor["buildings"] & themed_buildings
        if unknown:
            raise ValueError(f"{floor['name']} has unknown buildings: {sorted(unknown)}")
        if overlap:
            raise ValueError(f"buildings appear in multiple floor themes: {sorted(overlap)}")
        if floor["multiplier"] <= 1:
            raise ValueError(f"{floor['name']} must have a production bonus above x1")
        if floor["price"] <= previous_price:
            raise ValueError("floor prices must increase in sequential purchase order")
        themed_buildings.update(floor["buildings"])
        previous_price = floor["price"]


def fmt_time(seconds):
    if seconds < 60:
        return f"{seconds:.0f}s"
    if seconds < 3600:
        return f"{seconds / 60:.1f}m"
    return f"{seconds / 3600:.1f}h"


def simulate(click_rate=CLICK_RATE, autoclick=True, seed_bank=0.0,
             label="active (3 clicks/s)", skin_multiplier=1.0, verbose=True):
    validate_floor_config()
    owned = [0] * len(BUILDINGS)
    upgrades = [0] * len(BUILDINGS)  # upgrade levels bought per building
    floors_owned = [False] * len(FLOORS)
    click_level = 0
    auto_power = 0  # power line level (0 = no autoclicker)
    auto_speed = 0  # speed line level
    bank = float(seed_bank)  # idle players need a tiny seed to place building #1
    t = 0.0
    first_buy = {}
    first_buy_building_cps = {}
    floor_buy = {}
    floor_buy_details = {}

    def floor_multiplier(i):
        name = BUILDINGS[i][0]
        for floor_index, floor in enumerate(FLOORS):
            if floors_owned[floor_index] and name in floor["buildings"]:
                return floor["multiplier"]
        return 1.0

    def b_cps(i):
        # Goo's strongest-owned multiplier applies universally to buildings. It
        # therefore affects both live production and the buildings-only offline
        # rate. The floor factor is separate and stacks multiplicatively.
        return (BUILDINGS[i][2] * (2 ** upgrades[i]) * skin_multiplier
                * floor_multiplier(i))

    def building_cps():
        return sum(owned[i] * b_cps(i) for i in range(len(BUILDINGS)))

    def matching_cps(floor):
        return sum(
            owned[i] * b_cps(i)
            for i, (name, _, _) in enumerate(BUILDINGS)
            if name in floor["buildings"]
        )

    def auto_cps():
        return AUTO_POWER_VAL[auto_power] * AUTO_SPEED_VAL[auto_speed]

    def cps():  # passive income (no manual clicking)
        return building_cps() + auto_cps()

    def income():
        return cps() + click_rate * (2 ** click_level)

    if verbose:
        print(f"\n=== {label}; goo x{skin_multiplier:.2f} ===")
        print(f"{'event':<44}{'time':>8}{'cost':>16}{'CpS after':>14}{'auto%bld':>10}")

    def ratio():
        b = building_cps()
        return (auto_cps() / b * 100) if b > 0 else float("inf")

    while t < SIM_END_HOURS * 3600:
        # Candidates: next copy of each building, available building upgrades,
        # the next sequential floor, next click level, and next autoclick
        # power/speed level.
        options = []
        for i, (name, base, _) in enumerate(BUILDINGS):
            cost = base * (GROWTH ** owned[i])
            options.append((cost / b_cps(i), cost, "b", i))
            lvl = upgrades[i]
            if lvl < len(UPGRADE_TIERS) and owned[i] >= UPGRADE_TIERS[lvl][0]:
                u_cost = base * UPGRADE_TIERS[lvl][1]
                delta = owned[i] * b_cps(i)  # doubling adds current output
                options.append((u_cost / delta, u_cost, "u", i))
        if click_rate > 0:
            c_cost = CLICK_BASE_COST * (CLICK_COST_GROWTH ** click_level)
            delta = click_rate * (2 ** click_level)  # doubling adds 2^n CpC
            options.append((c_cost / delta, c_cost, "c", None))
        if autoclick:
            if auto_power + 1 < len(AUTO_POWER_VAL):
                cost = AUTO_POWER_COST[auto_power + 1]
                delta = (AUTO_POWER_VAL[auto_power + 1] - AUTO_POWER_VAL[auto_power]) \
                    * AUTO_SPEED_VAL[auto_speed]
                if delta > 0:
                    options.append((cost / delta, cost, "ap", None))
            # Speed only matters (and is only offered) once a clicker is owned.
            if auto_power > 0 and auto_speed + 1 < len(AUTO_SPEED_VAL):
                cost = AUTO_SPEED_COST[auto_speed + 1]
                delta = AUTO_POWER_VAL[auto_power] \
                    * (AUTO_SPEED_VAL[auto_speed + 1] - AUTO_SPEED_VAL[auto_speed])
                if delta > 0:
                    options.append((cost / delta, cost, "as", None))

        # A floor competes on the immediate production it adds to buildings the
        # player already owns. A zero-output theme has no finite payback, so the
        # capacity-blind buyer waits until at least one matching producer exists.
        next_floor = next(
            (i for i, is_owned in enumerate(floors_owned) if not is_owned),
            None,
        )
        if next_floor is not None:
            floor = FLOORS[next_floor]
            delta = matching_cps(floor) * (floor["multiplier"] - 1.0)
            if delta > 0:
                cost = floor["price"]
                options.append((cost / delta, cost, "f", next_floor))

        options.sort()
        inc = income()
        if inc > 0:
            # Buy the best-payback option, waiting to afford it.
            payback, cost, kind, idx = options[0]
            next_best_payback = options[1][0] if len(options) > 1 else float("inf")
            wait = max(0.0, (cost - bank) / inc)
        else:
            # No income yet (idle bootstrap): buy the best-payback option we can
            # already afford from the seed bank; if none, we're stuck.
            affordable = [o for o in options if o[1] <= bank]
            if not affordable:
                break
            payback, cost, kind, idx = affordable[0]
            next_best_payback = affordable[1][0] if len(affordable) > 1 else float("inf")
            wait = 0.0
        t += wait
        bank += wait * inc - cost

        if kind == "b":
            owned[idx] += 1
            name = BUILDINGS[idx][0]
            if name not in first_buy:
                first_buy[name] = t
                first_buy_building_cps[name] = building_cps()
                if verbose:
                    print(f"{name:<44}{fmt_time(t):>8}{cost:>16,.0f}"
                          f"{cps():>14,.1f}{ratio():>9.0f}%")
        elif kind == "u":
            upgrades[idx] += 1
            tag = f"{BUILDINGS[idx][0]} upgrade x{2 ** upgrades[idx]}"
            if verbose:
                print(f"{tag:<44}{fmt_time(t):>8}{cost:>16,.0f}"
                      f"{cps():>14,.1f}{ratio():>9.0f}%")
        elif kind == "c":
            click_level += 1
            if verbose:
                print(f"{'Clicking Power lv' + str(click_level):<44}"
                      f"{fmt_time(t):>8}{cost:>16,.0f}{cps():>14,.1f}{ratio():>9.0f}%")
        elif kind == "ap":
            auto_power += 1
            tag = f"Autoclick Power lv{auto_power} ({auto_cps():,.0f}/s)"
            if verbose:
                print(f"{tag:<44}{fmt_time(t):>8}{cost:>16,.0f}"
                      f"{cps():>14,.1f}{ratio():>9.0f}%")
        elif kind == "as":
            auto_speed += 1
            tag = f"Autoclick Speed lv{auto_speed} ({AUTO_SPEED_VAL[auto_speed]}/s)"
            if verbose:
                print(f"{tag:<44}{fmt_time(t):>8}{cost:>16,.0f}"
                      f"{cps():>14,.1f}{ratio():>9.0f}%")
        elif kind == "f":
            floor = FLOORS[idx]
            delta = matching_cps(floor) * (floor["multiplier"] - 1.0)
            floors_owned[idx] = True
            floor_buy[floor["name"]] = t
            floor_buy_details[floor["name"]] = {
                "time": t,
                "cost": cost,
                "production_gain": delta,
                "payback": payback,
                "next_best_payback": next_best_payback,
            }
            if verbose:
                tag = f"{floor['name']} x{floor['multiplier']:.2f}"
                print(f"{tag:<44}{fmt_time(t):>8}{cost:>16,.0f}"
                      f"{cps():>14,.1f}{ratio():>9.0f}%")

        if BUILDINGS[-1][0] in first_buy:
            break

    total_buildings = sum(owned)
    if verbose:
        print(f"\nfinal: t={fmt_time(t)}  CpS={cps():,.0f}  placed={total_buildings}  "
              f"auto={auto_cps():,.0f}/s (P{auto_power} S{auto_speed})")
    return {
        "first_buy": first_buy,
        "first_buy_building_cps": first_buy_building_cps,
        "floor_buy": floor_buy,
        "floor_buy_details": floor_buy_details,
        "final_time": t,
        "final_building_cps": building_cps(),
        "final_auto_cps": auto_cps(),
        "final_auto_share": auto_cps() / building_cps() if building_cps() else float("inf"),
        "total_buildings": total_buildings,
    }


def print_floor_economy_spot_check():
    """Print floor and target-milestone timing at the required goo strengths."""
    multipliers = [1.00, 1.25, 1.75]
    profiles = [
        ("active (3 clicks/s)", {"click_rate": CLICK_RATE, "seed_bank": 0}),
        ("idle (0 clicks/s)", {"click_rate": 0, "seed_bank": 15}),
    ]
    floor_names = [floor["name"] for floor in FLOORS]

    for profile_name, profile_args in profiles:
        print(f"\n=== floor economy spot-check: {profile_name} ===")
        print(f"{'goo':>6}{'Factory':>11}{'Floor 1':>11}{'Research':>11}"
              f"{'Floor 2':>11}{'Portal':>11}{'Floor 3':>11}"
              f"{'Time Mach.':>11}{'placed':>9}{'auto%bld':>10}")
        for multiplier in multipliers:
            result = simulate(
                skin_multiplier=multiplier,
                verbose=False,
                **profile_args,
            )
            building_times = result["first_buy"]
            floor_times = result["floor_buy"]
            times = [
                building_times["Cookie Factory"],
                floor_times[floor_names[0]],
                building_times["Research Facility"],
                floor_times[floor_names[1]],
                building_times["Portal"],
                floor_times[floor_names[2]],
                building_times["Time Machine"],
            ]
            print(
                f"x{multiplier:>4.2f}"
                + "".join(f"{fmt_time(event_time):>11}" for event_time in times)
                + f"{result['total_buildings']:>9}"
                + f"{result['final_auto_share'] * 100:>9.2f}%"
            )


def print_paid_skin_headroom():
    """Show how much active pacing remains under a future x2.0 paid skin."""
    print("\n=== paid-skin headroom (active 3 clicks/s) ===")
    print(f"{'goo':>6}{'Floor 3':>12}{'Time Machine':>14}{'vs x1.25':>12}")
    expected = simulate(skin_multiplier=1.25, verbose=False)["final_time"]
    for multiplier in (1.25, 1.75, 2.00):
        result = simulate(skin_multiplier=multiplier, verbose=False)
        floor_three = result["floor_buy"][FLOORS[2]["name"]]
        print(f"x{multiplier:>4.2f}{fmt_time(floor_three):>12}"
              f"{fmt_time(result['final_time']):>14}"
              f"{result['final_time'] / expected * 100:>11.0f}%")


if __name__ == "__main__":
    simulate(skin_multiplier=1.25, label="expected active (3 clicks/s)")
    simulate(click_rate=0.0, seed_bank=15,
             label="expected idle (0 clicks/s; buildings + autoclick only)",
             skin_multiplier=1.25)
    print_floor_economy_spot_check()
    print_paid_skin_headroom()
