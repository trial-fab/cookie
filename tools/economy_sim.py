"""Pacing simulation for the ClickGame economy rebalance.

Models players buying greedily by payback time (cost / production gained) and
validates time-to-unlock for each building tier, the clicking-power curve, and
the autoclick "idle route" (power x speed).

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
    ("Research Facility", 330_000_000, 70_000),
    ("Portal", 5_100_000_000, 450_000),
    ("Time Machine", 75_000_000_000, 3_000_000),
]
GROWTH = 1.15

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


def fmt_time(seconds):
    if seconds < 60:
        return f"{seconds:.0f}s"
    if seconds < 3600:
        return f"{seconds / 60:.1f}m"
    return f"{seconds / 3600:.1f}h"


def simulate(click_rate=CLICK_RATE, autoclick=True, seed_bank=0.0,
             label="active (3 clicks/s)"):
    owned = [0] * len(BUILDINGS)
    upgrades = [0] * len(BUILDINGS)  # upgrade levels bought per building
    click_level = 0
    auto_power = 0  # power line level (0 = no autoclicker)
    auto_speed = 0  # speed line level
    bank = float(seed_bank)  # idle players need a tiny seed to place building #1
    t = 0.0
    first_buy = {}

    def b_cps(i):
        return BUILDINGS[i][2] * (2 ** upgrades[i])

    def building_cps():
        return sum(owned[i] * b_cps(i) for i in range(len(BUILDINGS)))

    def auto_cps():
        return AUTO_POWER_VAL[auto_power] * AUTO_SPEED_VAL[auto_speed]

    def cps():  # passive income (no manual clicking)
        return building_cps() + auto_cps()

    def income():
        return cps() + click_rate * (2 ** click_level)

    print(f"\n=== {label} ===")
    print(f"{'event':<28}{'time':>8}{'cost':>16}{'CpS after':>14}{'auto%bld':>10}")

    def ratio():
        b = building_cps()
        return (auto_cps() / b * 100) if b > 0 else float("inf")

    while t < SIM_END_HOURS * 3600:
        # Candidates: next copy of each building, available building upgrades,
        # next click level, next autoclick power/speed level.
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

        options.sort()
        inc = income()
        if inc > 0:
            # Buy the best-payback option, waiting to afford it.
            payback, cost, kind, idx = options[0]
            wait = max(0.0, (cost - bank) / inc)
        else:
            # No income yet (idle bootstrap): buy the best-payback option we can
            # already afford from the seed bank; if none, we're stuck.
            affordable = [o for o in options if o[1] <= bank]
            if not affordable:
                break
            payback, cost, kind, idx = affordable[0]
            wait = 0.0
        t += wait
        bank += wait * inc - cost

        if kind == "b":
            owned[idx] += 1
            name = BUILDINGS[idx][0]
            if name not in first_buy:
                first_buy[name] = t
                print(f"{name:<28}{fmt_time(t):>8}{cost:>16,.0f}"
                      f"{cps():>14,.1f}{ratio():>9.0f}%")
        elif kind == "u":
            upgrades[idx] += 1
            tag = f"{BUILDINGS[idx][0]} upgrade x{2 ** upgrades[idx]}"
            print(f"{tag:<28}{fmt_time(t):>8}{cost:>16,.0f}"
                  f"{cps():>14,.1f}{ratio():>9.0f}%")
        elif kind == "c":
            click_level += 1
            print(f"{'Clicking Power lv' + str(click_level):<28}"
                  f"{fmt_time(t):>8}{cost:>16,.0f}{cps():>14,.1f}{ratio():>9.0f}%")
        elif kind == "ap":
            auto_power += 1
            tag = f"Autoclick Power lv{auto_power} ({auto_cps():,.0f}/s)"
            print(f"{tag:<28}{fmt_time(t):>8}{cost:>16,.0f}"
                  f"{cps():>14,.1f}{ratio():>9.0f}%")
        elif kind == "as":
            auto_speed += 1
            tag = f"Autoclick Speed lv{auto_speed} ({AUTO_SPEED_VAL[auto_speed]}/s)"
            print(f"{tag:<28}{fmt_time(t):>8}{cost:>16,.0f}"
                  f"{cps():>14,.1f}{ratio():>9.0f}%")

        if BUILDINGS[-1][0] in first_buy:
            break

    total_buildings = sum(owned)
    print(f"\nfinal: t={fmt_time(t)}  CpS={cps():,.0f}  placed={total_buildings}  "
          f"auto={auto_cps():,.0f}/s (P{auto_power} S{auto_speed})")
    return first_buy


if __name__ == "__main__":
    simulate()
    simulate(click_rate=0.5, label="casual (0.5 clicks/s)")
    simulate(click_rate=0.0, seed_bank=15,
             label="idle (0 clicks/s; buildings + autoclick only)")
