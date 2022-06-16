export script_name = "Note Browser"
export script_description = "Loads a set of timestamped notes and adds options to mark them or jump between them."
export script_version = "1.3.1"
export script_namespace = "arch.NoteBrowser"
export script_author = "arch1t3cht"

-- This script allows loading a collection of subtitle QC notes prefixed by timestamps,
-- and allows navigation between mentioned lines in Aegisub.
-- It doesn't add any functionality of showing the content of the notes, as that would
-- likely take more time to set up properly than it would save. The script is mostly meant
-- to save the effort of scrolling through subtitles trying to find the line that was mentioned in a note.
--
-- Note format:
-- A note is any line starting with a timestamp of the form hh:mm:ss or mm:ss .
-- (As a consequence, lines starting with timestamps like 00:01:02.34 including centiseconds
-- will also be recognized as a note, however the centiseconds will be ignored.)
--
-- A file of notes can be organized into different sections (say, collecting notes on different
-- topics or from different authors - the latter being the motivation for the macro names).
-- A section is started by a line of the form [<section_name>], where the
-- section's name <section_name> must not contain a closing bracket.
--
-- Any line not matching one of these two formats is skipped. Section names and timestamps are the only
-- things that are parsed.
--
-- Example:
--
-- 0:01 - General note 1
-- 1:50 - General note 2
--
-- [TLC]
-- 3:24 - yabai should be translated as "terrible" instead.
--
-- [Timing]
-- 1:55 - Scene bleed
-- 2:10 - Flashing subs
--
-- Most of the script's functions should be self-explanatory with this.
-- The one tricky element is "Jump to next/previous note by the same author":
-- This will jump to the next note whose author is *the author of the last note
-- the user jumped to using the ordinary "Jump to next/previous note" command.
-- While this may seem counter-intuitive, this ensures that successively using
-- "Jump to next/previous note by author" will indeed always jump to notes of the
-- same author, even after arriving at a subtitle line with multiple notes on it.


default_config = {
    mark: false,
}

haveDepCtrl, DependencyControl = pcall(require, "l0.DependencyControl")
local config
local fun
local depctrl

if haveDepCtrl
    depctrl = DependencyControl({
        feed: "https://raw.githubusercontent.com/arch1t3cht/Aegisub-Scripts/main/DependencyControl.json",
        {
            {"l0.Functional", version: "0.6.0", url: "https://github.com/TypesettingTools/Functional",
              feed: "https://raw.githubusercontent.com/TypesettingTools/Functional/master/DependencyControl.json"},
        }
    })
    config = depctrl\getConfigHandler(default_config, "config", false)
    fun = depctrl\requireModules!
else
    id = () -> nil
    config = {c: default_config, load: id, write: id}
    fun = require "l0.Functional"


current_notes = {}
notes_owners = {}
current_all_notes = {}
local current_author


clear_markers = (subs) ->
    for si, line in ipairs(subs)
        continue if line.class != "dialogue"
        line.text = line.text\gsub("{|QC|[^}]+}", "")\gsub("- |QC|[^|]+|", "")
        line.effect = line.effect\gsub("%[QC%-[^%]]*%]", "")
        subs[si] = line


index_of_closest = (times, ms) ->
    local closest
    mindist = 15000

    for si, time in pairs(times)
        continue if time == nil
        diff = math.abs(time - ms)
        if diff < mindist
            mindist = diff
            closest = si

    return closest


note_cleanup = (notes) ->
  note_tbl, timecode = {}, 0

  -- Removes empty lines and space padding in notes
  notes = notes\gsub("\n[%s]*\n", "\n")\gsub("\n[%s]+", "\n")
  notelines = fun.string.split notes, "\n"
  for line in *notelines
    -- Add [author name] or lines before first timecode without any change
    if timecode == 0 and not line\match("^%[?%d+:%d+:%d+") or line\match("^%[[^%]]+%]$")
      table.insert(note_tbl, line)
    else
      timecode = 1
      if line\match "^%[?%d+:%d+:%d+"
        table.insert(note_tbl, line)
      else
        -- Convert multiline note to a single line seperated by line breaker
        note_tbl[#note_tbl] ..= "\\N#{line}"

  return note_tbl


patch_for_mpvqc = (lines) ->
    return lines unless #[true for line in *lines when line\match "^generator.*mpvQC"] > 0
    patched_lines = {}
    for line in *lines
        if line\match "^%[[%d:]+%]"
            section_header = line\match "^%[[^%]]+%] %[([^%]]+)%].*"
            qc = line\gsub("^%[([%d:]+)%] %[[^%]]-%](.*)$", "%1 -%2")
            table.insert(patched_lines, "[#{section_header}]")
            table.insert(patched_lines, qc)

    return patched_lines


load_notes = (subs) ->
    config\load()
    btn, result = aegisub.dialog.display({{
        class: "label",
        label: "Paste your QC notes here:                                                                                                               ",
        x: 0, y: 0, width: 2, height: 1,
    },{
        class: "checkbox",
        name: "mark",
        value: config.c.mark,
        label: "Mark lines with notes",
        x: 0, y: 1, width: 1, height: 1,
    },{
        class: "checkbox",
        name: "inline",
        value: config.c.inline,
        label: "Add qc notes to line",
        x: 1, y: 1, width: 1, height: 1,
    },{
        class: "textbox",
        name: "notes",
        x: 0, y: 2, width: 2, height: 10,
    }})

    return if not btn

    notes = result.notes\gsub("\r\n", "\n")
    notelines = note_cleanup notes
    notelines = patch_for_mpvqc notelines

    current_section = "N"
    newnotes = {}
    report = {}

    for i, line in ipairs(notelines)
        newsection = line\match("^%[([^%]]*)%]$")
        if newsection
            current_section = newsection
            continue

        timestamp = line\match("^%d+:%d+:%d+") or line\match("^%d+:%d+")
        continue if not timestamp

        hours, minutes, seconds = line\match("^(%d+):(%d+):(%d+)")
        sminutes, sseconds = line\match("^(%d+):(%d+)")

        hours or= 0
        minutes or= sminutes
        seconds or= sseconds

        ms = 1000 * (3600 * hours + 60 * minutes + seconds)

        newnotes[current_section] or= {}
        table.insert(newnotes[current_section], ms)

        qc_report = line\match("^[%d:%s%.%-]+(.*)")\gsub("{", "[")\gsub("}", "]")
        report[ms] or= {}
        report[ms] = qc_report

    for k, v in pairs(newnotes)
        table.sort(v)

    current_notes = newnotes
    notes_owners = {}
    allnotes = {}
    for k, v in pairs(newnotes)
        for i, n in ipairs(v)
            notes_owners[n] or= {}
            table.insert(notes_owners[n], k)
            table.insert(allnotes, n)
    table.sort(allnotes)
    current_all_notes = allnotes
    current_author = nil

    clear_markers(subs)

    config.c.mark = result.mark
    config.c.inline = result.inline
    config\write()
    if result.mark
        sections = fun.table.keys(current_notes)
        table.sort(sections)
        for i, section in ipairs(sections)
            for ni, ms in ipairs(current_notes[section])
                si = index_of_closest({i,line.start_time for i, line in ipairs(subs) when line.class == "dialogue"}, ms)
                continue unless si
                line = subs[si]
                line.text ..= "{|QC|#{report[ms]}|}" if result.inline
                line.effect ..= "[QC-#{section}]"
                subs[si] = line


jump_to = (forward, same, subs, sel) ->
    if #current_all_notes == 0
        aegisub.log("No notes loaded!\n")
        aegisub.cancel()

    si = sel[1]

    pool = current_all_notes
    if same and current_author != nil
        pool = current_notes[current_author]

    -- we do this dynamically, since lines might have changed of shifted since loading the notes.
    subtitle_times = {i,line.start_time for i, line in ipairs(subs) when line.class == "dialogue"}
    lines_with_notes_rev = {}
    for _, n in ipairs pool
      closest_lines_with_notes = index_of_closest(subtitle_times, n)
      continue unless closest_lines_with_notes
      lines_with_notes_rev[closest_lines_with_notes] = n

    lines_with_notes = fun.table.keys lines_with_notes_rev

    -- yeeeeeah there are marginally faster algorithms, but that's not necessary at this scale. Let's keep it clean and simple.
    table.sort(lines_with_notes)
    for i=1,#lines_with_notes
        ind = if forward then i else #lines_with_notes + 1 - i
        comp = if forward then ((a,b) -> a > b) else ((a, b) -> a < b)
        new_si = lines_with_notes[ind]

        if comp(new_si, si)
            if not same
                -- if there are multiple notes on this line, pick one at random. It's very hard to think up a scenario
                -- where this would cause problems and not be easily avoidable.
                corresponding_note = lines_with_notes_rev[new_si]
                if corresponding_note != nil
                    owners = notes_owners[corresponding_note]
                    current_author = owners[1] if #owners >= 1
            return {new_si}, new_si


mymacros = {}

wrap_register_macro = (name, ...) ->
    if haveDepCtrl
        table.insert(mymacros, {name, ...})
    else
        aegisub.register_macro("#{script_name}/#{name}", ...)

wrap_register_macro("Load notes", "Load QC notes", load_notes)
wrap_register_macro("Jump to next note", "Jump to the next note", (...) -> jump_to(true, false, ...))
wrap_register_macro("Jump to previous note", "Jump to the previous note", (...) -> jump_to(false, false, ...))
wrap_register_macro("Jump to next note by author", "Jump to the next note with the same author", (...) -> jump_to(true, true, ...))
wrap_register_macro("Jump to previous note by author", "Jump to the previous note with the same author", (...) -> jump_to(false, true, ...))
wrap_register_macro("Clear all markers", "Clear all the [QC-...] markers that were added when loading the notes", clear_markers)

if haveDepCtrl
    depctrl\registerMacros(mymacros)
