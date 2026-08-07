#!/usr/bin/env python3
"""Build the ClickGame music curation workbook using only the Python standard library."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import urllib.parse
import zipfile
from collections import Counter
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr


SHEET_NAMES = ["README", "Track Catalog", "Cue Map", "Pool Membership", "Lists"]


def col_name(index: int) -> str:
    value = ""
    while index:
        index, remainder = divmod(index - 1, 26)
        value = chr(65 + remainder) + value
    return value


def cell_ref(row: int, column: int) -> str:
    return f"{col_name(column)}{row}"


def inline_cell(row: int, column: int, value, style: int = 0) -> str:
    ref = cell_ref(row, column)
    style_attr = f' s="{style}"' if style else ""
    if value is None or value == "":
        return f'<c r="{ref}"{style_attr}/>'
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return f'<c r="{ref}"{style_attr}><v>{value}</v></c>'
    text = escape(str(value))
    return f'<c r="{ref}" t="inlineStr"{style_attr}><is><t xml:space="preserve">{text}</t></is></c>'


def row_xml(row_number: int, values, styles=None, height=None) -> str:
    styles = styles or {}
    height_attr = f' ht="{height}" customHeight="1"' if height else ""
    cells = "".join(
        inline_cell(row_number, index, value, styles.get(index, 0))
        for index, value in enumerate(values, start=1)
    )
    return f'<row r="{row_number}"{height_attr}>{cells}</row>'


def validation_xml(kind: str, sqref: str, formula: str, *, allow_blank=True) -> str:
    attrs = [f'type="{kind}"', f'sqref="{sqref}"', 'showErrorMessage="1"']
    if allow_blank:
        attrs.append('allowBlank="1"')
    if kind == "list":
        attrs.append('showDropDown="0"')
    return f'<dataValidation {" ".join(attrs)}><formula1>{escape(formula)}</formula1></dataValidation>'


def worksheet_xml(
    rows,
    max_column: int,
    *,
    widths=None,
    freeze=None,
    auto_filter=None,
    validations=None,
    merges=None,
    hyperlinks=None,
    selected=False,
) -> str:
    max_row = max(1, len(rows))
    dimension = f"A1:{cell_ref(max_row, max_column)}"
    view_bits = ['workbookViewId="0"']
    if selected:
        view_bits.append('tabSelected="1"')
    pane = ""
    if freeze:
        x_split, y_split, top_left = freeze
        pane = (
            f'<pane xSplit="{x_split}" ySplit="{y_split}" topLeftCell="{top_left}" '
            'activePane="bottomRight" state="frozen"/>'
        )
    cols = ""
    if widths:
        cols = "<cols>" + "".join(
            f'<col min="{start}" max="{end}" width="{width}" customWidth="1"/>'
            for start, end, width in widths
        ) + "</cols>"
    merge_xml = ""
    if merges:
        merge_xml = f'<mergeCells count="{len(merges)}">' + "".join(
            f'<mergeCell ref="{ref}"/>' for ref in merges
        ) + "</mergeCells>"
    filter_xml = f'<autoFilter ref="{auto_filter}"/>' if auto_filter else ""
    validation_xmls = validations or []
    validations_block = ""
    if validation_xmls:
        validations_block = f'<dataValidations count="{len(validation_xmls)}">' + "".join(validation_xmls) + "</dataValidations>"
    hyperlink_block = ""
    if hyperlinks:
        hyperlink_block = f'<hyperlinks>' + "".join(
            f'<hyperlink ref="{ref}" r:id="rId{index}"/>'
            for index, (ref, _url) in enumerate(hyperlinks, start=1)
        ) + "</hyperlinks>"
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        f'<dimension ref="{dimension}"/>'
        f'<sheetViews><sheetView {" ".join(view_bits)}>{pane}</sheetView></sheetViews>'
        '<sheetFormatPr defaultRowHeight="15"/>'
        f'{cols}<sheetData>{"".join(rows)}</sheetData>{filter_xml}{merge_xml}{validations_block}{hyperlink_block}'
        '<pageMargins left="0.25" right="0.25" top="0.5" bottom="0.5" header="0.3" footer="0.3"/>'
        '</worksheet>'
    )


def hyperlink_rels_xml(hyperlinks) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        + "".join(
            f'<Relationship Id="rId{index}" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" '
            f'Target={quoteattr(url)} TargetMode="External"/>'
            for index, (_ref, url) in enumerate(hyperlinks, start=1)
        )
        + '</Relationships>'
    )


def styles_xml() -> str:
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="5">
    <font><sz val="11"/><name val="Aptos"/><family val="2"/></font>
    <font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Aptos Display"/></font>
    <font><b/><color rgb="FF152033"/><sz val="11"/><name val="Aptos"/></font>
    <font><b/><color rgb="FFFFFFFF"/><sz val="18"/><name val="Aptos Display"/></font>
    <font><u val="single"/><color rgb="FF0563C1"/><sz val="11"/><name val="Aptos"/></font>
  </fonts>
  <fills count="7">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF152033"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF2F75B5"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFD9EAF7"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFE699"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="2">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    <border><left style="thin"><color rgb="FFD0D7E5"/></left><right style="thin"><color rgb="FFD0D7E5"/></right><top style="thin"><color rgb="FFD0D7E5"/></top><bottom style="thin"><color rgb="FFD0D7E5"/></bottom><diagonal/></border>
  </borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="10">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="2" fillId="4" borderId="1" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="3" fillId="2" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center"/></xf>
    <xf numFmtId="0" fontId="4" fillId="0" borderId="1" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="5" borderId="1" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="6" borderId="1" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
    <xf numFmtId="2" fontId="0" fillId="0" borderId="1" xfId="0" applyAlignment="1"><alignment vertical="top"/></xf>
    <xf numFmtId="0" fontId="1" fillId="3" borderId="1" xfId="0" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
  </cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
  <dxfs count="0"/>
  <tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/>
</styleSheet>'''


def parse_duration(value) -> int | None:
    try:
        parts = [int(part) for part in str(value).split(":")]
    except (TypeError, ValueError):
        return None
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    return None


def build_readme(catalog_count: int, snapshot_date: str):
    values = [
        (["ClickGame Music Planning Workbook", ""], {1: 4}, 30),
        (["Companion", "docs/music.md"], {1: 2, 2: 3}, None),
        (["Catalog snapshot", snapshot_date], {1: 2, 2: 3}, None),
        (["Catalog rows", catalog_count], {1: 2, 2: 3}, None),
        (["Source", "https://tunestogo.net/"], {1: 2, 2: 5}, None),
        (["", ""], {}, None),
        (["Working rules", ""], {1: 9}, 22),
        (["1", "Rights coverage is required before a source file is uploaded or shipped."], {1: 2, 2: 3}, None),
        (["2", "Track ID is the stable join key used by Cue Map and Pool Membership."], {1: 2, 2: 3}, None),
        (["3", "Audience Lane is internal curation: Playful, Synth, or Crossover."], {1: 2, 2: 3}, None),
        (["4", "Ordinary quest completion uses a stinger; arc completion may take over the full soundtrack."], {1: 2, 2: 3}, None),
        (["5", "Floor music triggers only on a committed unlock, never on saved-state initialization."], {1: 2, 2: 3}, None),
        (["6", "Duration eligibility means strictly shorter than seven minutes; file size and sample rate still require verification."], {1: 2, 2: 3}, None),
        (["", ""], {}, None),
        (["First curation pass", "Select a 12-track vertical slice before scaling to the 51-track target."], {1: 9, 2: 3}, 22),
        (["Slice", "Intro orbit, intro descent, three floor premieres, Core emergence, Old Goo backstory, arc completion, and four ambient tracks."], {1: 2, 2: 3}, None),
        (["Status flow", "Discovered > Shortlisted > Licensed > Downloaded > Uploaded > Moderated > In Build"], {1: 2, 2: 3}, None),
        (["Note", "Source metadata is imported as provided and may contain malformed fields. Review shortlisted rows against the source page."], {1: 2, 2: 6}, None),
    ]
    rows = [row_xml(index, row, styles, height) for index, (row, styles, height) in enumerate(values, start=1)]
    xml = worksheet_xml(
        rows,
        2,
        widths=[(1, 1, 24), (2, 2, 110)],
        freeze=(0, 0, "A1"),
        merges=["A1:B1", "A7:B7"],
        hyperlinks=[("B5", "https://tunestogo.net/")],
        selected=True,
    )
    return xml, [("B5", "https://tunestogo.net/")]


TRACK_HEADERS = [
    "Track ID", "Title", "Artist", "Source Page", "MP3 URL", "Download Filename",
    "Duration", "Duration Seconds", "Roblox Duration Eligible", "Release Year",
    "Source Genre", "Source Mood", "Tags", "Audience Lane", "Energy 1-5",
    "Dialogue Safe", "Loop Quality", "Intro Length Seconds", "Ending Type",
    "Curation Status", "Intended Use Notes", "Shortlist Rank", "License State",
    "License Evidence", "Commercial Game Permitted", "Roblox Upload Permitted",
    "Transcoding Permitted", "Fade Loop Cue Edits Permitted", "Approved Credit Text",
    "File Size MB", "Sample Rate kHz", "Roblox Asset ID", "Upload Owner Group",
    "Experience Permission", "Moderation Status", "Normalized Volume", "Listening Notes",
    "Data Quality Notes",
]


def build_track_catalog(catalog):
    title_counts = Counter(str(track.get("title") or "").strip().casefold() for track in catalog)
    rows = [row_xml(1, TRACK_HEADERS, {index: 1 for index in range(1, len(TRACK_HEADERS) + 1)}, 42)]
    hyperlinks = []
    for row_number, track in enumerate(catalog, start=2):
        title = str(track.get("title") or "").strip()
        artist = str(track.get("artist") or "").strip()
        audio_url = str(track.get("audio_path") or "").strip()
        source_url = "https://tunestogo.net/?q=" + urllib.parse.quote(title)
        filename = urllib.parse.unquote(os.path.basename(urllib.parse.urlparse(audio_url).path))
        seconds = parse_duration(track.get("duration"))
        eligible = "Yes" if seconds is not None and seconds < 420 else "No"
        notes = []
        if not artist:
            notes.append("Source artist is blank; verify.")
        elif len(artist) > 100:
            notes.append("Source artist field appears malformed; verify on the source page.")
        if seconds is None:
            notes.append("Duration could not be parsed.")
        elif seconds >= 420:
            notes.append("Duration is not shorter than 7:00.")
        if not audio_url:
            notes.append("Source MP3 URL is blank.")
        if title_counts[title.casefold()] > 1:
            notes.append("Source title is duplicated; use Track ID as identity.")
        values = [
            track.get("id"), title, artist, source_url, audio_url, filename,
            track.get("duration"), seconds, eligible, track.get("release_year"),
            track.get("genre"), track.get("mood"), track.get("tags"), "", "", "Unknown",
            "Unreviewed", "", "Unknown", "Discovered", "", "", "Unverified", "",
            "Unknown", "Unknown", "Unknown", "Unknown", "", "", "", "", "", "Unknown",
            "Not Uploaded", "", "", " ".join(notes),
        ]
        styles = {index: 3 for index in range(1, len(TRACK_HEADERS) + 1)}
        styles[4] = 5
        styles[5] = 5
        styles[9] = 6 if eligible == "No" else 3
        styles[38] = 6 if notes else 3
        rows.append(row_xml(row_number, values, styles))
        hyperlinks.append((f"D{row_number}", source_url))
        if audio_url:
            hyperlinks.append((f"E{row_number}", audio_url))

    validations = [
        validation_xml("list", "N2:N2000", "AudienceLane"),
        '<dataValidation type="whole" operator="between" allowBlank="1" showErrorMessage="1" sqref="O2:O2000"><formula1>1</formula1><formula2>5</formula2></dataValidation>',
        validation_xml("list", "P2:P2000", "YesNoUnknown"),
        validation_xml("list", "Q2:Q2000", "LoopQuality"),
        validation_xml("list", "S2:S2000", "EndingType"),
        validation_xml("list", "T2:T2000", "CurationStatus"),
        validation_xml("list", "W2:W2000", "LicenseState"),
        validation_xml("list", "Y2:AB2000", "YesNoUnknown"),
        validation_xml("list", "AH2:AH2000", "YesNoUnknown"),
        validation_xml("list", "AI2:AI2000", "ModerationStatus"),
        '<dataValidation type="decimal" operator="between" allowBlank="1" showErrorMessage="1" sqref="AJ2:AJ2000"><formula1>0</formula1><formula2>10</formula2></dataValidation>',
    ]
    widths = [
        (1, 1, 38), (2, 2, 28), (3, 3, 32), (4, 5, 42), (6, 6, 30),
        (7, 10, 16), (11, 13, 34), (14, 20, 19), (21, 21, 34), (22, 23, 18),
        (24, 29, 28), (30, 36, 20), (37, 38, 42),
    ]
    return worksheet_xml(
        rows,
        len(TRACK_HEADERS),
        widths=widths,
        freeze=(3, 1, "D2"),
        auto_filter=f"A1:{col_name(len(TRACK_HEADERS))}{len(rows)}",
        validations=validations,
        hyperlinks=hyperlinks,
    ), hyperlinks


CUE_HEADERS = [
    "Cue ID", "Moment", "Exact Trigger Contract", "Cue Type", "Priority",
    "Primary Track ID", "Fallback Pool ID", "Fade Out Seconds", "Fade In Seconds",
    "Minimum Hold Seconds", "Exit Condition", "Resume Policy", "Occurrence",
    "Story Moments Required", "Suppression Group", "Status", "Notes",
]


CUES = [
    ["INTRO_ORBIT", "Intro title and meteor orbit", "Intro presentation begins after essential audio preload or timeout.", "Cinematic", 100, "", "GROUND", 0, 2.0, "", "Play is pressed, Skip is pressed, or intro exits.", "Contextual Resume", "One Time + Replay", "Yes", "INTRO", "Planned", "Opening must tolerate the title decision timeout and loop cleanly."],
    ["INTRO_DESCENT", "Meteor descent", "Intro Play is accepted and the descent phase starts.", "Cinematic", 100, "", "GROUND", 1.0, 0.8, "", "Gameplay camera and HUD are restored.", "Contextual Resume", "One Time + Replay", "Yes", "INTRO", "Planned", "Impact remains an SFX and may duck this cue."],
    ["GOO_REVEAL", "Goo reveal and healing celebration", "Authoritative story transition begins the Goo reveal or healing celebration.", "Cinematic", 95, "", "GROUND", 1.5, 1.5, "", "Goob lore begins or celebration releases.", "Contextual Resume", "One Time + Replay", "Yes", "OPENING_STORY", "Planned", "May share a continuous track with GOOB_LORE after listening review."],
    ["GOOB_LORE", "Goob lore and Mixer unlock", "Story enters the lore dialogue presentation.", "Cinematic", 95, "", "GROUND", 2.0, 2.0, "", "Lore completes and the Mixer unlock presentation releases.", "Contextual Resume", "One Time + Replay", "Yes", "OPENING_STORY", "Planned", "Prefer dialogue-safe arrangement."],
    ["QUEST_COMPLETE_STINGER", "Ordinary quest completion", "Accepted QuestCompleted transition after cascade coalescing.", "Stinger", 40, "", "", 0.15, 0.1, 1.0, "Stinger ends.", "Return to Previous", "Every Completion", "Yes", "QUEST_PRESENTATION", "Planned", "Cascaded completions produce one stinger; do not replace the full music track."],
    ["OPENING_ARC_COMPLETE", "Opening quest arc completion", "Accepted ArcCompleted transition for the opening arc.", "Major Milestone", 80, "", "GROUND", 2.0, 1.5, "", "Track ends or player returns to queue.", "Contextual Resume", "One Time + Replay", "Yes", "QUEST_PRESENTATION", "Planned", "Suppress weaker quest-completion stingers from the same transition batch."],
    ["FLOOR_INDUSTRY_UNLOCK", "Industry Floor reveal", "Post-commit local-player unlock of Industry Floor; never save initialization.", "Major Milestone", 85, "", "INDUSTRY", 2.0, 1.5, "", "Track ends naturally or a higher-priority cue begins.", "Fresh Ambient", "Once Per Unlock", "Yes", "FLOOR_UNLOCK", "Planned", "Continues after the reveal and unlocks the Industry ambient collection."],
    ["FLOOR_COMMERCE_UNLOCK", "Commerce Floor reveal", "Post-commit local-player unlock of Commerce Floor; never save initialization.", "Major Milestone", 85, "", "COMMERCE", 2.0, 1.5, "", "Track ends naturally or a higher-priority cue begins.", "Fresh Ambient", "Once Per Unlock", "Yes", "FLOOR_UNLOCK", "Planned", "Introduces Finance and Distribution with a polished electronic identity."],
    ["FLOOR_SCIENCE_UNLOCK", "Science Floor reveal", "Post-commit local-player unlock of Science Floor; never save initialization.", "Major Milestone", 85, "", "SCIENCE", 2.0, 1.5, "", "Track ends naturally or a higher-priority cue begins.", "Fresh Ambient", "Once Per Unlock", "Yes", "FLOOR_UNLOCK", "Planned", "Introduces the futuristic or cosmic collection."],
    ["CORE_EMERGENCE", "Ancient Core opens and Old Goo emerges", "Per-player Ancient Core activation presentation begins.", "Cinematic", 100, "", "POST_SAD_HOPEFUL", 1.5, 1.0, "", "Old Goo backstory reaches its emotional transition.", "Contextual Resume", "Once Per Run", "Yes", "OLD_GOO_STORY", "Planned", "Tense mystery rather than immediate sadness."],
    ["OLD_GOO_BACKSTORY", "Old Goo sad history", "Story dialogue reaches the authored backstory transition beat.", "Cinematic", 100, "", "POST_SAD_HOPEFUL", 2.5, 2.5, "", "Dialogue completes plus a short emotional tail.", "Fresh Ambient", "Once Per Run", "Yes", "OLD_GOO_STORY", "Planned", "Follow with calm or hopeful recovery music."],
    ["REBIRTH_FINALE", "End-of-run or rebirth presentation", "Committed rebirth presentation begins after gameplay authority accepts the reset.", "Cinematic", 100, "", "UNIVERSAL", 2.0, 1.5, "", "Next run presentation or gameplay music begins.", "Fresh Ambient", "Every Rebirth", "Yes", "REBIRTH", "Planned", "Do not let music become authority for the reset."],
]


def build_cue_map():
    rows = [row_xml(1, CUE_HEADERS, {index: 1 for index in range(1, len(CUE_HEADERS) + 1)}, 42)]
    for row_number, cue in enumerate(CUES, start=2):
        rows.append(row_xml(row_number, cue, {index: 3 for index in range(1, len(CUE_HEADERS) + 1)}, 48))
    validations = [
        validation_xml("list", "D2:D500", "CueType"),
        '<dataValidation type="whole" operator="between" allowBlank="1" showErrorMessage="1" sqref="E2:E500"><formula1>0</formula1><formula2>100</formula2></dataValidation>',
        validation_xml("list", "G2:G500", "PoolId"),
        validation_xml("list", "L2:L500", "ResumePolicy"),
        validation_xml("list", "M2:M500", "Occurrence"),
        validation_xml("list", "N2:N500", "YesNoUnknown"),
        validation_xml("list", "P2:P500", "CueStatus"),
    ]
    widths = [
        (1, 1, 28), (2, 2, 30), (3, 3, 58), (4, 5, 18), (6, 7, 28),
        (8, 10, 18), (11, 12, 38), (13, 16, 22), (17, 17, 52),
    ]
    return worksheet_xml(
        rows,
        len(CUE_HEADERS),
        widths=widths,
        freeze=(2, 1, "C2"),
        auto_filter=f"A1:Q{len(rows)}",
        validations=validations,
    )


POOL_HEADERS = [
    "Track ID", "Pool ID", "Weight", "Minimum Progression", "Recency Exclusion",
    "Recovery Role", "Enabled", "Notes",
]


def build_pool_membership():
    rows = [row_xml(1, POOL_HEADERS, {index: 1 for index in range(1, len(POOL_HEADERS) + 1)}, 42)]
    rows.append(row_xml(2, ["", "", 1, "", 8, "Standard", "Yes", "Add one row for each Track ID and Pool ID relationship."], {index: 3 for index in range(1, 9)}))
    validations = [
        validation_xml("list", "B2:B2000", "PoolId"),
        '<dataValidation type="decimal" operator="between" allowBlank="1" showErrorMessage="1" sqref="C2:C2000"><formula1>0</formula1><formula2>10</formula2></dataValidation>',
        '<dataValidation type="whole" operator="between" allowBlank="1" showErrorMessage="1" sqref="E2:E2000"><formula1>0</formula1><formula2>50</formula2></dataValidation>',
        validation_xml("list", "F2:F2000", "RecoveryRole"),
        validation_xml("list", "G2:G2000", "YesNoUnknown"),
    ]
    return worksheet_xml(
        rows,
        len(POOL_HEADERS),
        widths=[(1, 1, 38), (2, 2, 28), (3, 3, 14), (4, 4, 30), (5, 7, 20), (8, 8, 60)],
        freeze=(2, 1, "C2"),
        auto_filter="A1:H2",
        validations=validations,
    )


LISTS = {
    "AudienceLane": ["Playful", "Synth", "Crossover"],
    "CurationStatus": ["Discovered", "Shortlisted", "Licensed", "Downloaded", "Uploaded", "Moderated", "In Build", "Rejected"],
    "YesNoUnknown": ["Yes", "No", "Unknown"],
    "LoopQuality": ["Unreviewed", "Poor", "Usable", "Seamless", "Not Applicable"],
    "EndingType": ["Unknown", "Hard Stop", "Natural Tail", "Loop Friendly", "Fade Required"],
    "CueType": ["Cinematic", "Major Milestone", "Stinger", "Ambient"],
    "ResumePolicy": ["Contextual Resume", "Resume Manual", "Fresh Ambient", "Return to Previous", "Scene Owned"],
    "LicenseState": ["Unverified", "Pending", "Covered", "Excluded", "Expired"],
    "ModerationStatus": ["Not Uploaded", "Pending", "Approved", "Rejected", "Unavailable"],
    "CueStatus": ["Planned", "Track Assigned", "Uploaded", "Integrated", "Verified", "Disabled"],
    "PoolId": ["UNIVERSAL", "GROUND", "INDUSTRY", "COMMERCE", "SCIENCE", "POST_SAD_HOPEFUL", "STORY_UNLOCKED", "CINEMATIC", "CHILL"],
    "RecoveryRole": ["Standard", "Calm", "Hopeful", "Energy Bridge", "No Recovery"],
    "Occurrence": ["One Time + Replay", "Every Completion", "Once Per Unlock", "Once Per Run", "Every Rebirth"],
}


POOL_DEFINITIONS = [
    ["UNIVERSAL", "Universal", "Cross-progression ambient music.", "Available from the beginning.", 8],
    ["GROUND", "Ground and Early Game", "Playful cosmic curiosity and early bakery identity.", "Available from the beginning.", 8],
    ["INDUSTRY", "Industry", "Rhythmic, mechanical, energetic material.", "Industry Floor owned.", 8],
    ["COMMERCE", "Commerce", "Polished Finance and Distribution identity.", "Commerce Floor owned.", 8],
    ["SCIENCE", "Science", "Futuristic, synth-forward, cosmic material.", "Science Floor owned.", 8],
    ["POST_SAD_HOPEFUL", "Post-story Recovery", "Calm or hopeful recovery after sad and tense cues.", "Contextual only.", ""],
    ["STORY_UNLOCKED", "Encountered Story", "Story tracks available for manual playback after encounter.", "Per-track encounter.", 11],
    ["CINEMATIC", "Cinematic Browse", "Manually playable encountered cinematic cues.", "Per-track encounter.", ""],
    ["CHILL", "Chill Browse", "Calm and low-fatigue listening collection.", "Track-specific.", ""],
]


def build_lists():
    names = list(LISTS.keys())
    max_length = max(len(values) for values in LISTS.values())
    rows = []
    header = names + ["", "Pool Definition ID", "Display Name", "Description", "Unlock Rule", "Target Count"]
    rows.append(row_xml(1, header, {index: 1 for index in range(1, len(header) + 1)}, 42))
    for row_index in range(1, max(max_length, len(POOL_DEFINITIONS)) + 1):
        values = [LISTS[name][row_index - 1] if row_index <= len(LISTS[name]) else "" for name in names]
        values.append("")
        values.extend(POOL_DEFINITIONS[row_index - 1] if row_index <= len(POOL_DEFINITIONS) else ["", "", "", "", ""])
        styles = {index: 3 for index in range(1, len(values) + 1)}
        rows.append(row_xml(row_index + 1, values, styles))
    return worksheet_xml(
        rows,
        len(header),
        widths=[(1, len(names), 24), (len(names) + 1, len(names) + 1, 3), (len(names) + 2, len(names) + 3, 26), (len(names) + 4, len(names) + 5, 48), (len(names) + 6, len(names) + 6, 14)],
        freeze=(0, 1, "A2"),
        auto_filter=f"{col_name(len(names) + 2)}1:{col_name(len(header))}{len(rows)}",
    )


def defined_names_xml():
    entries = []
    for column, (name, values) in enumerate(LISTS.items(), start=1):
        entries.append(
            f'<definedName name="{name}">\'Lists\'!${col_name(column)}$2:${col_name(column)}${len(values) + 1}</definedName>'
        )
    return "<definedNames>" + "".join(entries) + "</definedNames>"


def content_types_xml() -> str:
    overrides = "".join(
        f'<Override PartName="/xl/worksheets/sheet{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        for index in range(1, len(SHEET_NAMES) + 1)
    )
    return f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  {overrides}
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>'''


def workbook_xml() -> str:
    sheets = "".join(
        f'<sheet name={quoteattr(name)} sheetId="{index}" r:id="rId{index}"/>'
        for index, name in enumerate(SHEET_NAMES, start=1)
    )
    return f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <bookViews><workbookView xWindow="0" yWindow="0" windowWidth="24000" windowHeight="14000"/></bookViews>
  <sheets>{sheets}</sheets>
  {defined_names_xml()}
  <calcPr calcId="191029" fullCalcOnLoad="1"/>
</workbook>'''


def workbook_rels_xml() -> str:
    relationships = "".join(
        f'<Relationship Id="rId{index}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{index}.xml"/>'
        for index in range(1, len(SHEET_NAMES) + 1)
    )
    relationships += f'<Relationship Id="rId{len(SHEET_NAMES) + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    return f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{relationships}</Relationships>'''


def root_rels_xml() -> str:
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>'''


def core_props_xml(timestamp: str) -> str:
    return f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title>ClickGame Music Planning</dc:title><dc:subject>Soundtrack curation and cue mapping</dc:subject><dc:creator>ClickGame</dc:creator><cp:lastModifiedBy>ClickGame</cp:lastModifiedBy>
  <dcterms:created xsi:type="dcterms:W3CDTF">{timestamp}</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">{timestamp}</dcterms:modified>
</cp:coreProperties>'''


def app_props_xml() -> str:
    titles = "".join(f'<vt:lpstr>{escape(name)}</vt:lpstr>' for name in SHEET_NAMES)
    return f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>ClickGame Workbook Builder</Application><DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop>
  <HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant><vt:lpstr>Worksheets</vt:lpstr></vt:variant><vt:variant><vt:i4>{len(SHEET_NAMES)}</vt:i4></vt:variant></vt:vector></HeadingPairs>
  <TitlesOfParts><vt:vector size="{len(SHEET_NAMES)}" baseType="lpstr">{titles}</vt:vector></TitlesOfParts>
</Properties>'''


def build_workbook(catalog_path: Path, output_path: Path, snapshot_date: str) -> None:
    with catalog_path.open("r", encoding="utf-8") as handle:
        catalog = json.load(handle)
    if not isinstance(catalog, list):
        raise ValueError("catalog JSON must be a list of track objects")

    readme_xml, readme_links = build_readme(len(catalog), snapshot_date)
    track_xml, track_links = build_track_catalog(catalog)
    worksheets = [readme_xml, track_xml, build_cue_map(), build_pool_membership(), build_lists()]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    timestamp = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        archive.writestr("[Content_Types].xml", content_types_xml())
        archive.writestr("_rels/.rels", root_rels_xml())
        archive.writestr("docProps/core.xml", core_props_xml(timestamp))
        archive.writestr("docProps/app.xml", app_props_xml())
        archive.writestr("xl/workbook.xml", workbook_xml())
        archive.writestr("xl/_rels/workbook.xml.rels", workbook_rels_xml())
        archive.writestr("xl/styles.xml", styles_xml())
        for index, xml in enumerate(worksheets, start=1):
            archive.writestr(f"xl/worksheets/sheet{index}.xml", xml)
        archive.writestr("xl/worksheets/_rels/sheet1.xml.rels", hyperlink_rels_xml(readme_links))
        archive.writestr("xl/worksheets/_rels/sheet2.xml.rels", hyperlink_rels_xml(track_links))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog-json", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--snapshot-date", default=dt.date.today().isoformat())
    args = parser.parse_args()
    build_workbook(args.catalog_json, args.output, args.snapshot_date)


if __name__ == "__main__":
    main()
