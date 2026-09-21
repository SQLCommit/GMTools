--[[
    GM Tools v1.0.4 - ImGui UI Rendering
    Sidebar + detail panel layout with categories, favorites, presets, and history views.
]]--

require 'common';

local chat  = require 'chat';
local imgui = require 'imgui';
local json  = require 'json';

local ui = {};

-- Cache table flags once.
local UI_TABLE_FLAGS = bit.bor(
    ImGuiTableFlags_RowBg,
    ImGuiTableFlags_BordersInnerH,
    ImGuiTableFlags_SizingStretchProp,
    ImGuiTableFlags_Resizable
);
local UI_TABLE_FLAGS_SCROLL = bit.bor(
    ImGuiTableFlags_RowBg,
    ImGuiTableFlags_BordersInnerH,
    ImGuiTableFlags_SizingStretchProp,
    ImGuiTableFlags_Resizable,
    ImGuiTableFlags_ScrollY
);
local UI_TABLE_FLAGS_POPUP = bit.bor(
    ImGuiTableFlags_RowBg,
    ImGuiTableFlags_BordersInnerH,
    ImGuiTableFlags_ScrollY,
    ImGuiTableFlags_SizingStretchProp
);

local function msg(...)
    local m = chat.header('gmtools');
    for _, part in ipairs({...}) do m:append(part); end
    return m;
end

-- Parse a multiline preset blob into a T{} of trimmed lines starting with '!'.
local function parse_preset_commands(raw_text)
    local cmds_list = T{};
    for line in raw_text:gmatch('[^\r\n]+') do
        local trimmed = line:match('^%s*(.-)%s*$');
        if (trimmed ~= '' and trimmed:sub(1, 1) == '!') then
            cmds_list:append(trimmed);
        end
    end
    return cmds_list;
end

-- Build a plain (JSON-serializable) gear export table for a job.
local function build_gear_export(job_name, slots, slot_order)
    local export = { job = job_name, slots = {} };
    for _, sn in ipairs(slot_order) do
        export.slots[sn] = {};
        local items = slots[sn] or T{};
        for _, item in ipairs(items) do
            table.insert(export.slots[sn], { id = item.id, name = item.name });
        end
    end
    return export;
end

-- Module references (set during init)
ui.commands = nil;
ui.presets  = nil;
ui.db       = nil;
ui.jobgear  = nil;
ui.settings = nil;

-- Window state
ui.is_open = { true, };

-- View modes
ui.VIEW_CATEGORIES   = 1;
ui.VIEW_FAVORITES    = 2;
ui.VIEW_PRESETS      = 3;
ui.VIEW_HISTORY      = 4;
ui.VIEW_JOBGEAR      = 5;
ui.VIEW_ITEM_SEARCH  = 6;
ui.current_view = 1;

-- Tab order for the TabBar. Module-level: no per-frame allocation.
local view_tabs = {
    { 'Categories',  ui.VIEW_CATEGORIES },
    { 'Favorites',   ui.VIEW_FAVORITES },
    { 'Presets',     ui.VIEW_PRESETS },
    { 'Job Gear',    ui.VIEW_JOBGEAR },
    { 'Item Search', ui.VIEW_ITEM_SEARCH },
    { 'History',     ui.VIEW_HISTORY },
};

-- Category selection (0-indexed for sidebar Selectable)
ui.selected_category = 0;

-- Per-command input buffers: indexed by "category_idx .. '_' .. cmd_idx"
-- Each entry is a table of arg values matching the command's args definition
ui.input_buffers = {};

-- Preset execution queue
ui.cmd_queue = T{};
ui.queue_total = 0;
ui.queue_delay = { 1.5, }; -- seconds between queued commands (ImGui slider buffer)
ui.queue_timer = 0;

-- Last executed command (for status bar)
ui.last_cmd = '';

-- UI reset: incrementing salt forces ImGui to forget saved column widths
ui.reset_pending = false;
ui.table_salt = 0;

-- Settings dirty flag (triggers sync + save)
ui.settings_dirty = false;

-- History search
ui.history_search = { '', };
ui.history_search_size = 256;

-- Custom preset builder
ui.new_preset_name = { '', };
ui.new_preset_name_size = 128;
ui.new_preset_desc = { '', };
ui.new_preset_desc_size = 256;
ui.new_preset_cmds = { '', };
ui.new_preset_cmds_size = 1024;

-- Preset edit mode
ui.editing_preset_id = nil;        -- nil = create mode, number = editing that preset ID
ui.queue_preset_name = '';         -- name of the currently running preset
ui.restore_defaults_confirm = false; -- confirmation flag for restore defaults

-- Job Gear editing state
ui.selected_job = { 0, }; -- combo index (0-based)
ui.jg_working = nil;       -- working copy: { [slot_name] = T{ {id=,name=}, ... } }
ui.jg_working_job = nil;   -- which job name the working copy is for
ui.jg_is_override = false; -- true if loaded from DB (has been saved)
ui.jg_add_slot = { 0, };  -- combo index for target slot (0-based)
ui.jg_add_id = { 0, };    -- single item ID input buffer
ui.jg_search_open = false; -- true when item search popup is open
ui.jg_search_slot = nil;   -- which slot name the search is targeting
ui.jg_search_text = { '', };
ui.jg_search_text_size = 128;
ui.jg_search_results = T{};

-- Item Search
ui.item_cache = nil;           -- { [i] = { id=, name=, type=, stack= }, ... }
ui.item_cache_building = false;
ui.item_cache_build_pos = 0;
ui.item_cache_count = 0;
ui.item_search_text = { '', };
ui.item_search_text_size = 128;
ui.item_search_results = T{};
ui.item_search_qty = { 1, };

-- Favorites cache (eliminates per-frame SQLite queries)
ui.favorites_cache = nil;     -- cached list from db.get_favorites()
ui.favorites_set = nil;       -- lookup set: { [cmd] = true }

-- Combo string cache (eliminates per-frame O(n^2) string rebuilding)
ui.combo_cache = {};          -- keyed by options table name

-- History cache (eliminates per-frame SQLite queries on History tab)
ui.history_cache = nil;
ui.history_cache_query = '';

-- Custom presets cache (eliminates per-frame SQLite + JSON decode on Presets tab)
ui.custom_presets_cache = nil;

-- GM Level filter (0-5, default 5 = show all)
ui.gm_level = { 5, }; -- combo index (0-based, matches perm values)
ui.gm_level_names = 'Player (0)\0GM (1)\0Senior GM (2)\0Admin (3)\0Super Admin (4)\0Developer (5)\0\0';
ui.gm_level_short = { [0] = 'P', [1] = 'GM', [2] = 'GM+', [3] = 'Adm', [4] = 'SAdm', [5] = 'Dev' };

-- Global command search (matches across all categories; cached, rebuilt only on query change)
ui.cmd_search = { '', };
ui.cmd_search_size = 128;
ui.cmd_search_cache = nil;   -- T{} of { ci=, cat=, cmdi=, cd= }
ui.cmd_search_last = nil;    -- last lowercased query used to build cache

-- One-shot keyboard-focus flags (set on tab switch / popup open)
ui.focus_item_search = false;
ui.focus_history     = false;
ui.focus_jg_search   = false;
ui.prev_view         = nil;  -- previous view, used to detect tab switches
ui.view_force        = false;-- force TabBar selection after a programmatic view change

-- Inline confirmation / error state
ui.preset_save_error    = nil;   -- message shown under the preset builder on a failed save
ui.preset_pending_del   = nil;   -- preset id awaiting delete confirmation
ui.history_clear_confirm = false;-- Clear History confirmation flag

local colors = {
    header   = { 1.0, 0.65, 0.26, 1.0 },
    success  = { 0.0, 1.0, 0.1, 1.0 },
    error    = { 1.0, 0.4, 0.4, 1.0 },
    muted    = { 0.6, 0.6, 0.6, 1.0 },
    fav_on   = { 1.0, 0.85, 0.0, 1.0 },
    fav_off  = { 0.5, 0.5, 0.5, 1.0 },
    preset   = { 0.4, 0.7, 1.0, 1.0 },
    running  = { 0.3, 1.0, 0.3, 1.0 },
    perm_hi  = { 1.0, 0.5, 0.5, 0.6 },
    run      = { 0.5, 0.9, 0.5, 1.0 }, -- consistent tint for '>'/Run actions
};

-- Cache permission colors by level.
local perm_badge_color = {
    [0] = colors.muted,  [1] = colors.muted,
    [2] = colors.header, [3] = colors.header,
    [4] = colors.perm_hi, [5] = colors.perm_hi,
};

-- Item types: warm weapons/armor, green consumables, blue currency/crystals, muted quest items.
local item_type_colors = {
    [2] = colors.muted,   -- Quest
    [4] = colors.header,  -- Weapon (warm)
    [5] = colors.header,  -- Armor  (warm)
    [7] = colors.run,     -- Usable (green)
    [8] = colors.preset,  -- Crystal (blue)
    [9] = colors.preset,  -- Currency (blue)
};

-- Pre-allocated ImGui size/position tables (eliminates per-frame table allocations)
local sizes = {
    sidebar       = { 140, -24 },
    panel         = { 0, -24 },
    window        = { 680, 450 },
    window_min    = { 500, 300 },
    window_max    = { FLT_MAX, FLT_MAX },
    window_pos    = { 100, 100 },
    progress_bar  = { -60, 0 },
    btn_run       = { 40, 0 },
    btn_edit      = { 36, 0 },
    btn_del       = { 32, 0 },
    btn_cancel    = { 80, 0 },
    multiline     = { 0, 80 },
    jg_table      = { 0, -56 },
    popup         = { 450, 350 },
    popup_results = { 0, -30 },
    item_table    = { 0, -1 },
};

-- Pre-allocated button style colors (eliminates per-frame table allocations)
local btn_colors = {
    view_active = { 0.3, 0.5, 0.8, 1.0 },
    stop        = { 0.8, 0.2, 0.2, 1.0 },
    stop_hover  = { 1.0, 0.3, 0.3, 1.0 },
    reset       = { 0.3, 0.3, 0.3, 1.0 },
};

-- Initialization

function ui.init(commands, presets, db, jobgear, s)
    ui.commands = commands;
    ui.presets  = presets;
    ui.db       = db;
    ui.jobgear  = jobgear;
    ui.settings = s;

    -- Apply saved settings to ImGui buffers
    if (s ~= nil) then
        ui.queue_delay[1] = s.queue_delay or 1.5;
        ui.gm_level[1]    = s.gm_level or 5;
    end
end

--- Sync ImGui buffer values back to the settings table.
function ui.sync_settings()
    if (ui.settings == nil) then return; end
    ui.settings.queue_delay = ui.queue_delay[1];
    ui.settings.gm_level    = ui.gm_level[1];
end

--- Apply externally changed settings to ImGui buffers.
function ui.apply_settings(s)
    ui.settings = s;
    if (s ~= nil) then
        ui.queue_delay[1] = s.queue_delay or 1.5;
        ui.gm_level[1]    = s.gm_level or 5;
    end
end

-- Favorites Cache

local function refresh_favorites_cache()
    ui.favorites_cache = ui.db.get_favorites();
    ui.favorites_set = {};
    for _, fav in ipairs(ui.favorites_cache) do
        ui.favorites_set[fav.cmd] = true;
    end
    ui.db.favorites_dirty = false;
end

local function get_cached_favorites()
    if (ui.db.favorites_dirty or ui.favorites_cache == nil) then
        refresh_favorites_cache();
    end
    return ui.favorites_cache;
end

local function is_favorite_cached(cmd)
    if (ui.db.favorites_dirty or ui.favorites_set == nil) then
        refresh_favorites_cache();
    end
    return ui.favorites_set[cmd] == true;
end

-- Custom Presets Cache

local function get_cached_custom_presets()
    if (ui.db.custom_presets_dirty or ui.custom_presets_cache == nil) then
        ui.custom_presets_cache = ui.db.get_custom_presets();
        ui.db.custom_presets_dirty = false;
    end
    return ui.custom_presets_cache;
end

-- History Cache

local function get_cached_history(query)
    if (ui.db.history_dirty or ui.history_cache == nil or ui.history_cache_query ~= query) then
        if (query ~= '') then
            ui.history_cache = ui.db.search_history(query);
        else
            ui.history_cache = ui.db.get_history(50);
        end
        ui.history_cache_query = query;
        ui.db.history_dirty = false;
    end
    return ui.history_cache;
end

-- Combo String Cache

local function get_combo_string(options_name)
    if (ui.combo_cache[options_name] ~= nil) then
        return ui.combo_cache[options_name];
    end

    local options = ui.commands[options_name];
    if (options == nil) then return '\0'; end

    local parts = {};
    for i, opt in ipairs(options) do
        if (options_name == 'zones') then
            parts[i] = ('%d: %s'):fmt(opt.id, opt.name);
        else
            parts[i] = opt.name;
        end
    end
    local items = table.concat(parts, '\0') .. '\0\0';
    ui.combo_cache[options_name] = items;
    return items;
end

-- Clipboard Helpers (wrapped in pcall for safety)

local function clipboard_set(text)
    local ok, err = pcall(ashita.misc.set_clipboard, text);
    return ok;
end

local function clipboard_get()
    local ok, result = pcall(ashita.misc.get_clipboard);
    if (ok) then return result; end
    return nil;
end

-- Salted table ID: changes on reset so ImGui forgets saved column widths
local function tid(name)
    return name .. '_s' .. tostring(ui.table_salt);
end

-- Consistent run/destructive button tints. Push/Pop always balanced.
local function run_button(label, size)
    imgui.PushStyleColor(ImGuiCol_Text, colors.run);
    local clicked;
    if (size ~= nil) then clicked = imgui.Button(label, size); else clicked = imgui.Button(label); end
    imgui.PopStyleColor();
    return clicked;
end

local function del_button(label, size)
    imgui.PushStyleColor(ImGuiCol_Text, colors.error);
    local clicked;
    if (size ~= nil) then clicked = imgui.Button(label, size); else clicked = imgui.Button(label); end
    imgui.PopStyleColor();
    return clicked;
end

-- Command Execution

local function execute_command(cmd)
    if (cmd == nil or cmd == '') then return; end
    AshitaCore:GetChatManager():QueueCommand(1, cmd);
    ui.last_cmd = cmd;
    ui.db.log_command(cmd);
end

local function get_input_key(cat_idx, cmd_idx)
    return tostring(cat_idx) .. '_' .. tostring(cmd_idx);
end

local function get_or_create_buffer(cat_idx, cmd_idx, cmd_def)
    local key = get_input_key(cat_idx, cmd_idx);
    if (ui.input_buffers[key] == nil) then
        local buf = {};
        for a = 1, #cmd_def.args do
            local arg = cmd_def.args[a];
            if (arg.type == 'int') then
                buf[a] = { arg.default or 0, };
            elseif (arg.type == 'float') then
                buf[a] = { arg.default or 0.0, };
            elseif (arg.type == 'string') then
                buf[a] = { arg.default or '', };
            elseif (arg.type == 'select') then
                buf[a] = { 0, }; -- combo index (0-based)
            elseif (arg.type == 'bool') then
                buf[a] = { arg.default or false, };
            end
        end
        ui.input_buffers[key] = buf;
    end
    return ui.input_buffers[key];
end

local function build_command(cmd_def, buffers)
    local parts = T{ cmd_def.cmd };
    for a = 1, #cmd_def.args do
        local arg = cmd_def.args[a];
        local buf = buffers[a];
        if (arg.type == 'int') then
            parts:append(tostring(buf[1]));
        elseif (arg.type == 'float') then
            parts:append(('%.2f'):fmt(buf[1]));
        elseif (arg.type == 'string') then
            local val = buf[1];
            if (type(val) == 'string') then
                val = val:trim('\0');
            end
            if (val ~= nil and val ~= '') then
                parts:append(tostring(val));
            end
        elseif (arg.type == 'select') then
            local options = ui.commands[arg.options];
            local idx = buf[1] + 1; -- combo is 0-based, table is 1-based
            if (options ~= nil and idx >= 1 and idx <= #options) then
                local entry = options[idx];
                -- For jobs, use the name; for zones/weather, use the ID
                if (arg.options == 'jobs') then
                    parts:append(entry.name);
                else
                    parts:append(tostring(entry.id));
                end
            end
        elseif (arg.type == 'bool') then
            if (buf[1]) then
                parts:append('1');
            else
                parts:append('0');
            end
        end
    end
    return parts:concat(' ');
end

local function build_friendly_name(cmd_def, buffers)
    local parts = T{};
    for a = 1, #cmd_def.args do
        local arg = cmd_def.args[a];
        local buf = buffers[a];
        if (arg.type == 'int') then
            parts:append(tostring(buf[1]));
        elseif (arg.type == 'float') then
            parts:append(('%.1f'):fmt(buf[1]));
        elseif (arg.type == 'string') then
            local val = buf[1];
            if (type(val) == 'string') then val = val:trim('\0'); end
            if (val ~= nil and val ~= '') then parts:append(val); end
        elseif (arg.type == 'select') then
            local options = ui.commands[arg.options];
            local idx = buf[1] + 1;
            if (options ~= nil and idx >= 1 and idx <= #options) then
                parts:append(options[idx].name);
            end
        elseif (arg.type == 'bool') then
            parts:append(buf[1] and 'On' or 'Off');
        end
    end
    if (#parts > 0) then
        return cmd_def.name .. ': ' .. parts:concat(' ');
    end
    return cmd_def.name;
end

-- Item Cache (incremental build over multiple frames)

local ITEM_CACHE_MAX_ID = 29000;
local ITEM_CACHE_PER_FRAME = 2000;

local function build_item_cache_step()
    if (not ui.item_cache_building) then return; end

    local res_mgr = AshitaCore:GetResourceManager();
    if (res_mgr == nil) then
        ui.item_cache_building = false;
        return;
    end

    if (ui.item_cache == nil) then
        ui.item_cache = T{};
    end

    local start_id = ui.item_cache_build_pos;
    local end_id = math.min(start_id + ITEM_CACHE_PER_FRAME - 1, ITEM_CACHE_MAX_ID);

    for id = start_id, end_id do
        local item = res_mgr:GetItemById(id);
        if (item ~= nil and item.Name ~= nil) then
            local name = item.Name[1];
            if (name ~= nil and name ~= '' and name ~= '.' and name ~= '(Undefined)') then
                ui.item_cache:append({
                    id    = id,
                    name  = name,
                    type  = item.Type or 0,
                    stack = item.StackSize or 1,
                });
            end
        end
    end

    ui.item_cache_build_pos = end_id + 1;
    ui.item_cache_count = #ui.item_cache;

    if (ui.item_cache_build_pos > ITEM_CACHE_MAX_ID) then
        ui.item_cache_building = false;
        print(msg(chat.success(('Item cache built: %d items'):fmt(ui.item_cache_count))));
    end
end

local function do_item_search(query)
    ui.item_search_results = T{};
    if (ui.item_cache == nil or query == nil or query == '') then return; end

    local q = query:lower();
    local count = 0;
    for _, item in ipairs(ui.item_cache) do
        if (item.name:lower():find(q, 1, true) ~= nil) then
            ui.item_search_results:append(item);
            count = count + 1;
            if (count >= 100) then break; end
        end
    end
end

-- Item type names for display
local item_type_names = {
    [0]  = 'Nothing',  [1] = 'Item',     [2] = 'Quest',    [3] = 'Fish',
    [4]  = 'Weapon',   [5] = 'Armor',    [6] = 'Linkshell', [7] = 'Usable',
    [8]  = 'Crystal',  [9] = 'Currency', [10] = 'Furnish', [11] = 'Plant',
    [12] = 'Flowerpot', [13] = 'Puppet', [14] = 'Mannequin', [15] = 'Book',
    [16] = 'Relic',    [17] = 'Maze',
};

-- Preset Queue Processing

function ui.process_queue()
    -- Incrementally build item cache if in progress
    build_item_cache_step();

    if (#ui.cmd_queue == 0) then return; end

    -- Don't dispatch commands during zone transitions or character select
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return; end
    local party = mem:GetParty();
    if (party == nil or (party:GetMemberZone(0) or 0) == 0) then return; end

    local now = os.clock();
    if (now - ui.queue_timer < ui.queue_delay[1]) then return; end

    local cmd = ui.cmd_queue[1];
    table.remove(ui.cmd_queue, 1);
    execute_command(cmd);
    ui.queue_timer = now;

    if (#ui.cmd_queue == 0) then
        ui.queue_preset_name = '';
        print(msg(chat.success('Preset complete.')));
    end
end

local function run_preset(preset)
    ui.cmd_queue = T{};
    for _, cmd in ipairs(preset.commands) do
        ui.cmd_queue:append(cmd);
    end
    ui.queue_total = #ui.cmd_queue;
    ui.queue_preset_name = preset.name;
    ui.queue_timer = os.clock() - ui.queue_delay[1]; -- run first immediately
    print(msg(chat.message('Running preset: '), chat.success(preset.name),
        chat.message((' (%d cmds, %.1fs delay)'):fmt(ui.queue_total, ui.queue_delay[1]))));
end

function ui.stop_queue()
    local remaining = #ui.cmd_queue;
    ui.cmd_queue = T{};
    ui.queue_total = 0;
    ui.queue_preset_name = '';
    if (remaining > 0) then
        print(msg(chat.error(('Preset stopped (%d commands skipped).'):fmt(remaining))));
    end
end

function ui.export_job_gear(job_name)
    if (ui.jobgear == nil) then return false; end

    local job = nil;
    for _, j in ipairs(ui.jobgear.jobs) do
        if (j.name == job_name:upper()) then
            job = j;
            break;
        end
    end
    if (job == nil) then
        print(msg(chat.error('Unknown job: ' .. job_name .. '. Use 3-letter abbreviation (WAR, MNK, etc.).')));
        return false;
    end

    -- Get slots (DB override or defaults)
    local slots;
    if (ui.db.has_job_gear_override(job.name)) then
        local db_slots = ui.db.get_job_gear(job.name);
        db_slots = db_slots or {};
        slots = {};
        for _, sn in ipairs(ui.jobgear.slot_order) do
            slots[sn] = db_slots[sn] or T{};
        end
    else
        slots = job.slots;
    end

    local export = build_gear_export(job.name, slots, ui.jobgear.slot_order);

    local ok_enc, export_json = pcall(json.encode, export);
    if (ok_enc and export_json ~= nil) then
        clipboard_set(export_json);
        local item_count = ui.jobgear.count_items(slots);
        print(msg(chat.success(('%s gear exported to clipboard (%d items).'):fmt(job.name, item_count))));
        return true;
    end
    print(msg(chat.error('Failed to encode gear data.')));
    return false;
end

function ui.import_job_gear()
    if (ui.jobgear == nil or ui.jg_working == nil or ui.jg_working_job == nil) then
        print(msg(chat.error('Open the Job Gear tab and select a job first.')));
        return false;
    end

    local clip = clipboard_get();
    if (clip == nil or clip == '') then
        print(msg(chat.error('Clipboard is empty.')));
        return false;
    end

    local ok_dec, data = pcall(json.decode, clip);
    if (not ok_dec or type(data) ~= 'table' or type(data.slots) ~= 'table') then
        print(msg(chat.error('Clipboard does not contain valid gear JSON.')));
        return false;
    end

    local imported = 0;
    for _, sn in ipairs(ui.jobgear.slot_order) do
        if (type(data.slots[sn]) == 'table') then
            ui.jg_working[sn] = T{};
            for _, item in ipairs(data.slots[sn]) do
                if (type(item) == 'table' and type(item.id) == 'number' and item.id > 0) then
                    local name = item.name;
                    if (name == nil or name == '') then
                        local res = AshitaCore:GetResourceManager();
                        if (res ~= nil) then
                            local ri = res:GetItemById(item.id);
                            if (ri ~= nil and ri.Name ~= nil and ri.Name[1] ~= nil and ri.Name[1] ~= '' and ri.Name[1] ~= '.') then
                                name = ri.Name[1];
                            end
                        end
                        if (name == nil or name == '') then
                            name = ('Item #%d'):fmt(item.id);
                        end
                    end
                    ui.jg_working[sn]:append({ id = item.id, name = name });
                    imported = imported + 1;
                end
            end
        end
    end

    local src = data.job or '?';
    print(msg(chat.success(('Imported %d items from %s gear into %s.'):fmt(imported, src, ui.jg_working_job))));
    return true;
end

function ui.start_item_search(query)
    -- Open the window and switch to item search tab
    ui.is_open[1] = true;
    ui.current_view = ui.VIEW_ITEM_SEARCH;
    ui.view_force = true; -- force the TabBar to follow this programmatic switch

    -- Start cache build if not already done
    if (ui.item_cache == nil and not ui.item_cache_building) then
        ui.item_cache_building = true;
        ui.item_cache_build_pos = 0;
        ui.item_cache_count = 0;
    end

    -- Set search text and run search if cache is ready
    if (query ~= nil and query ~= '') then
        ui.item_search_text[1] = query;
        if (ui.item_cache ~= nil and not ui.item_cache_building) then
            do_item_search(query);
        end
    end
end

function ui.run_preset_by_name(name)
    local presets_list = get_cached_custom_presets();
    for _, p in ipairs(presets_list) do
        if (p.name:lower() == name:lower()) then
            run_preset(p);
            return true;
        end
    end
    print(msg(chat.error('Preset not found: '), chat.message(name)));
    return false;
end

-- Argument Input Rendering

-- Return true on Enter in a string input to execute the command.
-- Use labels or placeholders that fit multi-argument rows.
local function render_args(cmd_def, cat_idx, cmd_idx)
    local buffers = get_or_create_buffer(cat_idx, cmd_idx, cmd_def);
    local uid = cat_idx .. '_' .. cmd_idx;
    local enter_pressed = false;

    for a = 1, #cmd_def.args do
        local arg = cmd_def.args[a];
        local buf = buffers[a];
        local id  = '##' .. uid .. '_' .. a;

        if (a > 1) then imgui.SameLine(); end

        if (arg.type == 'int') then
            imgui.TextDisabled(arg.name); imgui.SameLine(0, 3);
            imgui.SetNextItemWidth(70);
            imgui.InputInt(id, buf, 0, 0);
        elseif (arg.type == 'float') then
            imgui.TextDisabled(arg.name); imgui.SameLine(0, 3);
            imgui.SetNextItemWidth(70);
            imgui.InputFloat(id, buf, 0, 0, '%.1f');
        elseif (arg.type == 'string') then
            imgui.SetNextItemWidth(130);
            if (imgui.InputTextWithHint(id, arg.name, buf, 128, ImGuiInputTextFlags_EnterReturnsTrue)) then
                enter_pressed = true;
            end
        elseif (arg.type == 'select') then
            local options = ui.commands[arg.options];
            if (options ~= nil) then
                local items = get_combo_string(arg.options);
                imgui.TextDisabled(arg.name); imgui.SameLine(0, 3);
                imgui.SetNextItemWidth(160);
                imgui.Combo(id, buf, items);
            end
        elseif (arg.type == 'bool') then
            imgui.Checkbox(arg.name .. id, buf);
        end
    end

    return enter_pressed;
end

-- Sidebar Rendering

local function render_sidebar()
    imgui.BeginChild('##sidebar', sizes.sidebar, ImGuiChildFlags_Borders);
        for i, cat in ipairs(ui.commands.categories) do
            local is_selected = (ui.selected_category == i - 1);
            if (imgui.Selectable(cat.name .. '##cat_' .. i, is_selected)) then
                ui.selected_category = i - 1;
            end
        end
    imgui.EndChild();
end

-- Command Table Rendering (Detail Panel)

-- Append a command line to the preset builder (A3 "Send to preset builder").
local function send_to_preset_builder(cmd_line)
    local cur = ui.new_preset_cmds[1];
    if (type(cur) == 'string') then cur = cur:trim('\0'); else cur = ''; end
    if (cur == '') then
        ui.new_preset_cmds[1] = cmd_line;
    else
        ui.new_preset_cmds[1] = cur .. '\n' .. cmd_line;
    end
    ui.current_view = ui.VIEW_PRESETS;
    ui.view_force = true;
end

-- Render one 4-column command row (shared by the per-category table and the
-- global search results table). Performs no GM-level filtering itself.
local function render_command_row(cat_idx, category, cmd_idx, cmd_def)
    local cmd_perm = cmd_def.perm or 1;

    imgui.TableNextRow();

    -- Column 1: Command name + perm badge (C1 colored by tier)
    imgui.TableNextColumn();
    imgui.Text(cmd_def.name);
    if (cmd_perm > 1) then
        imgui.SameLine();
        imgui.TextColored(perm_badge_color[cmd_perm] or colors.muted,
            '[' .. (ui.gm_level_short[cmd_perm] or '?') .. ']');
    end

    -- Build command once (needed by tooltip, context menu, Run and Fav)
    local row_buffers = get_or_create_buffer(cat_idx, cmd_idx, cmd_def);
    local row_cmd = build_command(cmd_def, row_buffers);

    if (imgui.IsItemHovered()) then
        -- Escape % -> %% : SetTooltip printf-processes its argument.
        local tt = cmd_def.desc .. '\nSyntax: ' .. cmd_def.cmd .. '\nPermission: ' .. tostring(cmd_perm);
        imgui.SetTooltip((tt:gsub('%%', '%%%%')));
    end

    -- right-click context menu on the command name cell.
    if (imgui.BeginPopupContextItem('ctxcmd_' .. cat_idx .. '_' .. cmd_idx)) then
        if (imgui.Selectable('Copy command')) then clipboard_set(row_cmd); end
        if (imgui.Selectable('Copy syntax')) then clipboard_set(cmd_def.cmd); end
        if (imgui.Selectable('Add to favorites')) then
            if (not is_favorite_cached(row_cmd)) then
                ui.db.add_favorite(build_friendly_name(cmd_def, row_buffers), row_cmd, category.name);
            end
        end
        if (imgui.Selectable('Send to preset builder')) then send_to_preset_builder(row_cmd); end
        imgui.EndPopup();
    end

    -- Column 2: Argument inputs (Enter in a string arg fires the same execute path)
    imgui.TableNextColumn();
    local arg_enter = false;
    if (#cmd_def.args > 0) then
        arg_enter = render_args(cmd_def, cat_idx, cmd_idx);
        if (arg_enter) then
            row_cmd = build_command(cmd_def, row_buffers); -- rebuild with the just-entered value
        end
    else
        imgui.TextColored(colors.muted, '(none)');
    end

    -- Column 3: Execute button
    imgui.TableNextColumn();
    if (run_button('>##run_' .. cat_idx .. '_' .. cmd_idx) or arg_enter) then
        execute_command(row_cmd);
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Execute command');
    end

    -- Column 4: Favorite toggle (saves full command with current args)
    imgui.TableNextColumn();
    local is_fav = is_favorite_cached(row_cmd);
    if (is_fav) then
        imgui.PushStyleColor(ImGuiCol_Text, colors.fav_on);
    end
    if (imgui.Button((is_fav and '*' or '+') .. '##fav_' .. cat_idx .. '_' .. cmd_idx)) then
        if (is_fav) then
            ui.db.remove_favorite_by_cmd(row_cmd);
        else
            local friendly = build_friendly_name(cmd_def, row_buffers);
            ui.db.add_favorite(friendly, row_cmd, category.name);
        end
    end
    if (is_fav) then
        imgui.PopStyleColor();
    end
    if (imgui.IsItemHovered()) then
        -- Escape % -> %% : SetTooltip printf-processes its argument and row_cmd is user data.
        local rc = (row_cmd or ''):gsub('%%', '%%%%');
        imgui.SetTooltip(is_fav and ('Remove from favorites:\n' .. rc) or ('Add to favorites:\n' .. rc));
    end
end

-- Setup the shared 4-column command table header.
local function command_table_columns()
    imgui.TableSetupColumn('Command',   ImGuiTableColumnFlags_WidthFixed, 140);
    imgui.TableSetupColumn('Arguments', ImGuiTableColumnFlags_WidthStretch);
    imgui.TableSetupColumn('Run',       ImGuiTableColumnFlags_WidthFixed, 32);
    imgui.TableSetupColumn('Fav',       ImGuiTableColumnFlags_WidthFixed, 32);
    imgui.TableHeadersRow();
end

local function render_command_table(cat_idx, category)
    if (imgui.BeginTable(tid('##cmds_' .. cat_idx), 4, UI_TABLE_FLAGS)) then
        command_table_columns();

        local shown = 0;
        for cmd_idx, cmd_def in ipairs(category.commands) do
            -- Filter by GM level (perm defaults to 1 if not set)
            local cmd_perm = cmd_def.perm or 1;
            if (cmd_perm <= ui.gm_level[1]) then
                render_command_row(cat_idx, category, cmd_idx, cmd_def);
                shown = shown + 1;
            end
        end

        imgui.EndTable();

        -- empty-state when the GM-Level filter hides every command.
        if (shown == 0) then
            imgui.TextColored(colors.muted,
                ('No commands at GM Level %d or below. Raise the GM Level filter to see more.'):fmt(ui.gm_level[1]));
        end
    end
end

-- Cache command-search results until the lowercased query changes.
local function get_command_search_results(q)
    if (ui.cmd_search_last ~= q) then
        ui.cmd_search_cache = T{};
        local count = 0;
        for ci, cat in ipairs(ui.commands.categories) do
            for cmdi, cd in ipairs(cat.commands) do
                local hay = (cd.name .. ' ' .. cd.cmd .. ' ' .. (cd.desc or '')):lower();
                if (hay:find(q, 1, true) ~= nil) then
                    ui.cmd_search_cache:append({ ci = ci, cat = cat, cmdi = cmdi, cd = cd });
                    count = count + 1;
                    if (count >= 100) then break; end
                end
            end
            if (count >= 100) then break; end
        end
        ui.cmd_search_last = q;
    end
    return ui.cmd_search_cache;
end

local function render_command_search_table(results)
    if (#results == 0) then
        imgui.TextColored(colors.muted, 'No commands match your search.');
        return;
    end
    imgui.TextColored(colors.muted, ('%d match(es) (max 100)'):fmt(#results));
    if (imgui.BeginTable(tid('##cmdsearch'), 4, UI_TABLE_FLAGS)) then
        command_table_columns();
        for _, r in ipairs(results) do
            render_command_row(r.ci, r.cat, r.cmdi, r.cd);
        end
        imgui.EndTable();
    end
end

-- Favorites View

local function render_favorites()
    local favorites = get_cached_favorites();

    if (#favorites == 0) then
        imgui.TextColored(colors.muted, 'No favorites yet. Click + on any command to add it.');
        return;
    end

    if (imgui.BeginTable(tid('##favs'), 6, UI_TABLE_FLAGS)) then
        imgui.TableSetupColumn('Name',     ImGuiTableColumnFlags_WidthStretch, 65);
        imgui.TableSetupColumn('Command',  ImGuiTableColumnFlags_WidthStretch);
        imgui.TableSetupColumn('^',        ImGuiTableColumnFlags_WidthFixed, 24);
        imgui.TableSetupColumn('v',        ImGuiTableColumnFlags_WidthFixed, 24);
        imgui.TableSetupColumn('Run',      ImGuiTableColumnFlags_WidthFixed, 32);
        imgui.TableSetupColumn('Del',      ImGuiTableColumnFlags_WidthFixed, 32);
        imgui.TableHeadersRow();

        for idx, fav in ipairs(favorites) do
            imgui.TableNextRow();

            -- Name (C3: accent tone so it stays distinct from the command text)
            imgui.TableNextColumn();
            imgui.TextColored(colors.preset, fav.name);
            if (imgui.IsItemHovered() and fav.category ~= nil and fav.category ~= '') then
                imgui.SetTooltip('Category: ' .. fav.category .. '\nUsed: ' .. tostring(fav.use_count) .. ' times');
            end
            -- right-click menu (Copy / Run)
            if (imgui.BeginPopupContextItem('ctxfav_' .. fav.id)) then
                if (imgui.Selectable('Copy command')) then clipboard_set(fav.cmd); end
                if (imgui.Selectable('Run')) then
                    execute_command(fav.cmd);
                    ui.db.update_favorite_usage(fav.id);
                end
                imgui.EndPopup();
            end

            -- Command (C3: default text color; B5: tooltip when clipped)
            imgui.TableNextColumn();
            imgui.Text(fav.cmd);
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip((fav.cmd or ''):gsub('%%', '%%%%'));
            end

            -- Move up button
            imgui.TableNextColumn();
            if (idx == 1) then
                imgui.BeginDisabled();
            end
            if (imgui.Button('^##fav_up_' .. fav.id)) then
                ui.db.move_favorite_up(fav.id);
            end
            if (idx == 1) then
                imgui.EndDisabled();
            end

            -- Move down button
            imgui.TableNextColumn();
            if (idx == #favorites) then
                imgui.BeginDisabled();
            end
            if (imgui.Button('v##fav_dn_' .. fav.id)) then
                ui.db.move_favorite_down(fav.id);
            end
            if (idx == #favorites) then
                imgui.EndDisabled();
            end

            imgui.TableNextColumn();
            if (run_button('>##fav_run_' .. fav.id)) then
                execute_command(fav.cmd);
                ui.db.update_favorite_usage(fav.id);
            end

            imgui.TableNextColumn();
            if (del_button('x##fav_del_' .. fav.id)) then
                ui.db.remove_favorite(fav.id);
            end
            -- warn that single-favorite delete is immediate.
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip('Delete favorite (immediate, no undo).');
            end
        end

        imgui.EndTable();
    end
end

-- Presets View

local function clear_preset_builder()
    ui.new_preset_name[1] = '';
    ui.new_preset_desc[1] = '';
    ui.new_preset_cmds[1] = '';
    ui.editing_preset_id = nil;
    ui.preset_save_error = nil;
end

-- Validate preset inputs; return name/description/commands or set preset_save_error.
local function validate_preset_builder()
    local name = ui.new_preset_name[1]:trim('\0');
    local desc = ui.new_preset_desc[1]:trim('\0');
    local cmds_raw = ui.new_preset_cmds[1]:trim('\0');

    if (name == '') then
        ui.preset_save_error = 'Enter a preset name before saving.';
        return nil;
    end

    local cmds_list = parse_preset_commands(cmds_raw);
    if (#cmds_list == 0) then
        ui.preset_save_error = 'No valid commands found. Each command line must start with "!".';
        return nil;
    end

    ui.preset_save_error = nil;
    return name, desc, cmds_list;
end

local function render_presets()
    local is_running = #ui.cmd_queue > 0;

    -- Progress bar + stop button when a preset is running
    if (is_running) then
        local progress = ui.queue_total - #ui.cmd_queue;
        local label = ('Running: %s (%d/%d)'):fmt(
            ui.queue_preset_name ~= '' and ui.queue_preset_name or 'Preset',
            progress, ui.queue_total
        );
        imgui.ProgressBar(progress / ui.queue_total, sizes.progress_bar, label);
        imgui.SameLine();
        imgui.PushStyleColor(ImGuiCol_Button, btn_colors.stop);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, btn_colors.stop_hover);
        if (imgui.Button('Stop##preset_stop')) then
            ui.stop_queue();
        end
        imgui.PopStyleColor(2);
        imgui.Separator();
    end

    -- Settings row (D4: standardized 160px width)
    imgui.SetNextItemWidth(160);
    if (imgui.SliderFloat('Command Delay (sec)', ui.queue_delay, 0.5, 5.0, '%.1f')) then
        ui.settings_dirty = true;
    end
    imgui.ShowHelp('Time between each command in a preset.\nIncrease if commands are being skipped.\n1.5s works for most presets, use 2-3s for large ones.');

    if (ui.settings ~= nil) then
        local v = { ui.settings.show_on_load };
        if (imgui.Checkbox('Open window when addon loads', v)) then
            ui.settings.show_on_load = v[1];
            ui.settings_dirty = true;
        end
    end

    imgui.Separator();

    -- Unified preset list
    imgui.TextColored(colors.header, 'Presets');
    imgui.Separator();

    local presets_list = get_cached_custom_presets();
    if (#presets_list > 0) then
        for _, preset in ipairs(presets_list) do
            imgui.PushID('preset_' .. preset.id);

            -- Disable Run/Edit/Del while queue is active
            if (is_running) then imgui.BeginDisabled(); end

            if (run_button('Run', sizes.btn_run)) then
                run_preset(preset);
            end
            imgui.SameLine();
            if (imgui.Button('Edit', sizes.btn_edit)) then
                -- Populate builder with this preset's data
                ui.editing_preset_id = preset.id;
                ui.new_preset_name[1] = preset.name or '';
                ui.new_preset_desc[1] = preset.desc or '';
                -- Convert commands table back to newline-separated text
                local lines = T{};
                for _, cmd in ipairs(preset.commands) do
                    lines:append(tostring(cmd));
                end
                ui.new_preset_cmds[1] = lines:concat('\n');
            end
            imgui.SameLine();
            -- per-item delete confirmation (no immediate destroy).
            if (del_button('Del', sizes.btn_del)) then
                ui.preset_pending_del = preset.id;
            end

            if (is_running) then imgui.EndDisabled(); end

            imgui.SameLine();
            imgui.Text(preset.name);
            if (imgui.IsItemHovered()) then
                local tip = (preset.desc or '') .. '\n\nCommands:';
                for _, cmd in ipairs(preset.commands) do
                    tip = tip .. '\n  ' .. cmd;
                end
                tip = tip .. '\n\n(' .. #preset.commands .. ' commands)';
                -- Escape % -> %% : SetTooltip printf-processes its argument and tip contains user commands.
                imgui.SetTooltip((tip:gsub('%%', '%%%%')));
            end

            -- inline confirm row for this preset.
            if (ui.preset_pending_del == preset.id) then
                imgui.TextColored(colors.error, ('Delete "%s"?'):fmt(preset.name));
                imgui.SameLine();
                if (del_button('Yes##del_yes_' .. preset.id)) then
                    ui.db.delete_custom_preset(preset.id);
                    if (ui.editing_preset_id == preset.id) then
                        clear_preset_builder();
                    end
                    ui.preset_pending_del = nil;
                end
                imgui.SameLine();
                if (imgui.Button('Cancel##del_no_' .. preset.id)) then
                    ui.preset_pending_del = nil;
                end
            end
            imgui.PopID();
        end
    else
        imgui.TextColored(colors.muted, 'No presets. Create one below or use Restore Defaults.');
    end

    -- Preset builder (create or edit mode)
    imgui.NewLine();
    imgui.Separator();

    if (ui.editing_preset_id ~= nil) then
        imgui.TextColored(colors.header, 'Editing Preset');
        imgui.SameLine();
        imgui.TextColored(colors.success, '(ID: ' .. tostring(ui.editing_preset_id) .. ')');
    else
        imgui.TextColored(colors.header, 'Create New Preset');
    end

    imgui.PushItemWidth(240);
    imgui.InputTextWithHint('Name##new_preset', 'Preset name...', ui.new_preset_name, ui.new_preset_name_size);
    imgui.InputTextWithHint('Description##new_preset', 'Description...', ui.new_preset_desc, ui.new_preset_desc_size);
    imgui.PopItemWidth();

    imgui.PushItemWidth(400);
    imgui.InputTextMultiline('Commands##new_preset', ui.new_preset_cmds, ui.new_preset_cmds_size, sizes.multiline);
    imgui.PopItemWidth();
    imgui.ShowHelp('Enter one GM command per line (e.g., !setplayerlevel 99)');

    if (imgui.Button('Paste from Clipboard')) then
        local clip = clipboard_get();
        if (clip ~= nil and clip ~= '') then
            -- Try JSON decode first
            local ok, data = pcall(json.decode, clip);
            if (ok and type(data) == 'table' and data.commands ~= nil) then
                -- JSON preset format
                ui.new_preset_name[1] = data.name or '';
                ui.new_preset_desc[1] = data.desc or '';
                if (type(data.commands) == 'table') then
                    local lines = T{};
                    for _, cmd in ipairs(data.commands) do
                        lines:append(tostring(cmd));
                    end
                    ui.new_preset_cmds[1] = lines:concat('\n');
                end
                print(msg(chat.success('Preset pasted from clipboard (JSON): '), chat.message(data.name or '(unnamed)')));
            else
                -- Fallback: treat as newline-separated commands
                ui.new_preset_cmds[1] = clip;
                print(msg(chat.message('Pasted commands from clipboard (plain text).')));
            end
        else
            print(msg(chat.error('Clipboard is empty.')));
        end
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Paste a JSON preset or plain text commands from clipboard');
    end

    imgui.SameLine();
    if (ui.editing_preset_id ~= nil) then
        -- Edit mode: Save Changes + Cancel
        if (imgui.Button('Save Changes')) then
            local name, desc, cmds_list = validate_preset_builder();
            if (name ~= nil) then
                ui.db.update_custom_preset(ui.editing_preset_id, name, desc, cmds_list);
                print(msg(chat.success('Preset updated: '), chat.message(name)));
                clear_preset_builder();
            end
        end
        imgui.SameLine();
        if (imgui.Button('Cancel')) then
            clear_preset_builder();
        end
    else
        -- Create mode: Save Preset
        if (imgui.Button('Save Preset')) then
            local name, desc, cmds_list = validate_preset_builder();
            if (name ~= nil) then
                ui.db.save_custom_preset(name, desc, cmds_list);
                clear_preset_builder();
                print(msg(chat.success('Preset saved: '), chat.message(name)));
            end
        end
    end

    -- surface the failure reason inline.
    if (ui.preset_save_error ~= nil) then
        imgui.TextColored(colors.error, ui.preset_save_error);
    end

    -- Restore Defaults button
    imgui.NewLine();
    imgui.Separator();
    if (ui.restore_defaults_confirm) then
        imgui.TextColored(colors.error, 'This will delete ALL presets and re-import the built-in defaults.');
        if (imgui.Button('Yes, Restore Defaults')) then
            ui.db.clear_all_presets();
            ui.db.seed_defaults(ui.presets.defaults);
            clear_preset_builder();
            ui.restore_defaults_confirm = false;
            print(msg(chat.success('Presets restored to defaults.')));
        end
        imgui.SameLine();
        if (imgui.Button('Cancel##restore')) then
            ui.restore_defaults_confirm = false;
        end
    else
        if (imgui.Button('Restore Defaults')) then
            ui.restore_defaults_confirm = true;
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Delete all presets and re-import the built-in defaults.');
        end
    end
end

-- History View

local function render_history()
    -- focus the search field on the first frame of the History tab.
    if (ui.focus_history) then
        ui.focus_history = false;
        imgui.SetKeyboardFocusHere(0);
    end
    imgui.SetNextItemWidth(200);
    imgui.InputTextWithHint('Search##hist', 'Search history...', ui.history_search, ui.history_search_size);

    -- Clear History asks for confirmation instead of wiping immediately.
    imgui.SameLine();
    if (ui.history_clear_confirm) then
        if (del_button('Clear All?##hist_clear_yes')) then
            ui.db.clear_history();
            ui.history_clear_confirm = false;
        end
        imgui.SameLine();
        if (imgui.Button('Cancel##hist_clear_no')) then
            ui.history_clear_confirm = false;
        end
    else
        if (del_button('Clear History')) then
            ui.history_clear_confirm = true;
        end
    end

    local query = ui.history_search[1];
    if (type(query) == 'string') then
        query = query:trim('\0');
    else
        query = '';
    end

    local entries = get_cached_history(query);

    if (#entries == 0) then
        imgui.TextColored(colors.muted, 'No history entries.');
        return;
    end

    if (imgui.BeginTable(tid('##history'), 3, UI_TABLE_FLAGS)) then
        imgui.TableSetupColumn('Time',    ImGuiTableColumnFlags_WidthFixed, 70);
        imgui.TableSetupColumn('Command', ImGuiTableColumnFlags_WidthStretch);
        imgui.TableSetupColumn('Re-run',  ImGuiTableColumnFlags_WidthFixed, 40);
        imgui.TableHeadersRow();

        for _, entry in ipairs(entries) do
            imgui.TableNextRow();

            imgui.TableNextColumn();
            imgui.TextColored(colors.muted, entry.time_fmt or '');

            imgui.TableNextColumn();
            imgui.Text(entry.cmd);
            -- tooltip for clipped command text.
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip((entry.cmd or ''):gsub('%%', '%%%%'));
            end
            -- right-click menu (Copy / Re-run / Add to favorites).
            if (imgui.BeginPopupContextItem('ctxhist_' .. entry.id)) then
                if (imgui.Selectable('Copy command')) then clipboard_set(entry.cmd); end
                if (imgui.Selectable('Re-run')) then execute_command(entry.cmd); end
                if (imgui.Selectable('Add to favorites')) then
                    if (not is_favorite_cached(entry.cmd)) then
                        ui.db.add_favorite(entry.cmd, entry.cmd, 'History');
                    end
                end
                imgui.EndPopup();
            end

            imgui.TableNextColumn();
            if (run_button('>##hist_' .. entry.id)) then
                execute_command(entry.cmd);
            end
        end

        imgui.EndTable();
    end
end

-- Job Gear View (per-slot with customization)

-- Resolve item ID to name using FFXI resource manager (cached)
local item_name_cache = {};

local function resolve_item_name(id)
    local cached = item_name_cache[id];
    if (cached ~= nil) then return cached; end

    local res = AshitaCore:GetResourceManager();
    if (res ~= nil) then
        local item = res:GetItemById(id);
        if (item ~= nil and item.Name ~= nil and item.Name[1] ~= nil and item.Name[1] ~= '' and item.Name[1] ~= '.') then
            item_name_cache[id] = item.Name[1];
            return item.Name[1];
        end
    end
    local fallback = ('Item #%d'):fmt(id);
    item_name_cache[id] = fallback;
    return fallback;
end

-- Load job gear from DB override or hardcoded defaults
local function load_job_gear(job)
    local from_db = ui.db.has_job_gear_override(job.name);
    if (from_db) then
        local db_slots = ui.db.get_job_gear(job.name);
        db_slots = db_slots or {};
        ui.jg_working = {};
        for _, sn in ipairs(ui.jobgear.slot_order) do
            ui.jg_working[sn] = db_slots[sn] or T{};
        end
        ui.jg_is_override = true;
    else
        ui.jg_working = ui.jobgear.copy_slots(job.slots);
        ui.jg_is_override = false;
    end
    ui.jg_working_job = job.name;

    -- Reset add-item buffers
    ui.jg_add_slot[1] = 0;
    ui.jg_add_id[1] = 0;
end

-- Item search popup for job gear slots
local function render_jg_search_popup()
    if (not ui.jg_search_open) then return; end

    -- Auto-start cache build if needed
    if (ui.item_cache == nil and not ui.item_cache_building) then
        ui.item_cache_building = true;
        ui.item_cache_build_pos = 0;
        ui.item_cache_count = 0;
    end

    imgui.SetNextWindowSize(sizes.popup, ImGuiCond_FirstUseEver);

    if (imgui.BeginPopupModal('Item Search##jg_popup', nil, ImGuiWindowFlags_None)) then
        imgui.TextColored(colors.header, 'Adding to slot: ' .. (ui.jg_search_slot or '?'));

        -- Show progress if cache is still building
        if (ui.item_cache_building) then
            local progress = ui.item_cache_build_pos / ITEM_CACHE_MAX_ID;
            imgui.ProgressBar(progress, { -1, 0 }, ('Loading items... %d/' .. ITEM_CACHE_MAX_ID):fmt(ui.item_cache_build_pos));
        else
            -- Search box (A5: focus on first frame the box appears)
            if (ui.focus_jg_search) then
                ui.focus_jg_search = false;
                imgui.SetKeyboardFocusHere(0);
            end
            imgui.SetNextItemWidth(280);
            local changed = imgui.InputTextWithHint('##jg_popup_search', 'Search items...', ui.jg_search_text, ui.jg_search_text_size, ImGuiInputTextFlags_EnterReturnsTrue);
            imgui.SameLine();
            if (imgui.Button('Search') or changed) then
                local query = ui.jg_search_text[1];
                if (type(query) == 'string') then query = query:trim('\0'); end
                ui.jg_search_results = T{};
                if (ui.item_cache ~= nil and query ~= nil and query ~= '') then
                    local q = query:lower();
                    local count = 0;
                    for _, item in ipairs(ui.item_cache) do
                        if (item.name:lower():find(q, 1, true) ~= nil) then
                            ui.jg_search_results:append(item);
                            count = count + 1;
                            if (count >= 50) then break; end
                        end
                    end
                end
            end

            -- Results table
            if (#ui.jg_search_results > 0) then
                imgui.TextColored(colors.muted, ('%d results'):fmt(#ui.jg_search_results));

                if (imgui.BeginTable('##jg_popup_results', 3, UI_TABLE_FLAGS_POPUP, sizes.popup_results)) then
                    imgui.TableSetupColumn('Name', ImGuiTableColumnFlags_WidthStretch);
                    imgui.TableSetupColumn('ID',   ImGuiTableColumnFlags_WidthFixed, 55);
                    imgui.TableSetupColumn('Add',  ImGuiTableColumnFlags_WidthFixed, 32);
                    imgui.TableHeadersRow();

                    for i, item in ipairs(ui.jg_search_results) do
                        imgui.TableNextRow();
                        imgui.TableNextColumn();
                        imgui.Text(item.name);
                        imgui.TableNextColumn();
                        imgui.TextColored(colors.muted, tostring(item.id));
                        imgui.TableNextColumn();
                        if (imgui.Button('+##jgsr_' .. i)) then
                            -- Add item to the target slot
                            if (ui.jg_working ~= nil and ui.jg_search_slot ~= nil) then
                                if (ui.jg_working[ui.jg_search_slot] == nil) then
                                    ui.jg_working[ui.jg_search_slot] = T{};
                                end
                                ui.jg_working[ui.jg_search_slot]:append({ id = item.id, name = item.name });
                            end
                            ui.jg_search_open = false;
                            imgui.CloseCurrentPopup();
                        end
                        if (imgui.IsItemHovered()) then
                            imgui.SetTooltip('Add ' .. item.name .. ' to ' .. (ui.jg_search_slot or '?'));
                        end
                    end
                    imgui.EndTable();
                end
            elseif (ui.jg_search_text[1] ~= nil and ui.jg_search_text[1] ~= '') then
                imgui.TextColored(colors.muted, 'No results. Try a different search term.');
            else
                imgui.TextColored(colors.muted, 'Type an item name and press Search or Enter.');
            end
        end

        if (imgui.Button('Cancel', sizes.btn_cancel)) then
            ui.jg_search_open = false;
            imgui.CloseCurrentPopup();
        end

        imgui.EndPopup();
    else
        -- Popup was closed externally
        ui.jg_search_open = false;
    end
end

local function render_jobgear()
    if (ui.jobgear == nil) then
        imgui.TextColored(colors.error, 'Job gear module not loaded.');
        return;
    end

    -- Job selector combo (cached)
    if (ui.combo_cache['jg_jobs'] == nil) then
        local s = '';
        for _, job in ipairs(ui.jobgear.jobs) do
            s = s .. job.name .. ' - ' .. job.full_name .. '\0';
        end
        ui.combo_cache['jg_jobs'] = s .. '\0';
    end

    imgui.TextColored(colors.header, 'Select Job:');
    imgui.SameLine();
    imgui.PushItemWidth(200);
    local changed = imgui.Combo('##job_select', ui.selected_job, ui.combo_cache['jg_jobs']);
    imgui.PopItemWidth();

    local job_idx = ui.selected_job[1] + 1;
    local job = ui.jobgear.jobs[job_idx];
    if (job == nil) then return; end

    -- Load working copy when job changes
    if (changed or ui.jg_working_job ~= job.name) then
        load_job_gear(job);
    end

    -- Do not mutate a running queue or act on an empty loadout.
    local is_running    = #ui.cmd_queue > 0;
    local loadout_count = (ui.jg_working ~= nil) and ui.jobgear.count_items(ui.jg_working) or 0;
    local is_empty      = (loadout_count == 0);
    local EMPTY_TIP     = 'This loadout is empty - add items below first.';

    -- RUN group: Give All
    imgui.SameLine(0, 16);
    imgui.BeginDisabled(is_running or is_empty);
    local do_give = imgui.Button('Give All');
    imgui.EndDisabled();
    if (imgui.IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled)) then
        imgui.SetTooltip(is_empty and EMPTY_TIP or 'Give all items in this loadout via !additem');
    end
    if (do_give) then
        local cmds = ui.jobgear.build_commands(ui.jg_working);
        ui.cmd_queue = T{};
        for _, cmd in ipairs(cmds) do
            ui.cmd_queue:append(cmd);
        end
        ui.queue_total = #ui.cmd_queue;
        ui.queue_timer = os.clock() - ui.queue_delay[1];
        print(msg(chat.message('Giving ' .. job.name .. ' gear: '),
            chat.success(('%d items, %.1fs delay'):fmt(loadout_count, ui.queue_delay[1]))));
    end

    -- PERSIST group: Save as Default | Reset to Default | [Saved]
    imgui.SameLine(0, 16);
    imgui.BeginDisabled(is_empty);
    local do_save = imgui.Button('Save as Default');
    imgui.EndDisabled();
    if (imgui.IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled)) then
        imgui.SetTooltip(is_empty and EMPTY_TIP or 'Save current loadout to database.\nPersists across sessions.');
    end
    if (do_save) then
        ui.db.save_job_gear(job.name, ui.jg_working, ui.jobgear.slot_order);
        ui.jg_is_override = true;
        print(msg(chat.success('Saved ' .. job.name .. ' gear loadout.')));
    end

    if (ui.jg_is_override) then
        imgui.SameLine();
        imgui.BeginDisabled(is_running);
        local do_reset = imgui.Button('Reset to Default');
        imgui.EndDisabled();
        if (imgui.IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled)) then
            imgui.SetTooltip('Delete saved overrides and restore defaults.');
        end
        if (do_reset) then
            ui.db.delete_job_gear(job.name);
            ui.jg_working = ui.jobgear.copy_slots(job.slots);
            ui.jg_is_override = false;
            ui.jg_add_slot[1] = 0;
            ui.jg_add_id[1] = 0;
            print(msg(chat.success('Reset ' .. job.name .. ' gear to defaults.')));
        end
        imgui.SameLine();
        imgui.TextColored(colors.success, '[Saved]');
    end

    -- CLIPBOARD group: Copy | Paste
    imgui.SameLine(0, 16);
    imgui.BeginDisabled(is_empty);
    local do_copy = imgui.Button('Copy');
    imgui.EndDisabled();
    if (imgui.IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled)) then
        imgui.SetTooltip(is_empty and EMPTY_TIP or 'Copy gear loadout to clipboard as JSON');
    end
    if (do_copy) then
        local export = build_gear_export(job.name, ui.jg_working, ui.jobgear.slot_order);
        local ok_enc, export_json = pcall(json.encode, export);
        if (ok_enc and export_json ~= nil) then
            clipboard_set(export_json);
            print(msg(chat.success(('%s gear copied to clipboard (%d items).'):fmt(job.name, loadout_count))));
        else
            print(msg(chat.error('Failed to encode gear data.')));
        end
    end

    imgui.SameLine();
    if (imgui.Button('Paste')) then
        local clip = clipboard_get();
        if (clip ~= nil and clip ~= '') then
            local ok_dec, data = pcall(json.decode, clip);
            if (ok_dec and type(data) == 'table' and type(data.slots) == 'table') then
                -- Valid gear JSON — import into working copy
                local imported = 0;
                for _, sn in ipairs(ui.jobgear.slot_order) do
                    if (type(data.slots[sn]) == 'table') then
                        ui.jg_working[sn] = T{};
                        for _, item in ipairs(data.slots[sn]) do
                            if (type(item) == 'table' and type(item.id) == 'number' and item.id > 0) then
                                local name = item.name;
                                if (name == nil or name == '') then
                                    name = resolve_item_name(item.id);
                                end
                                ui.jg_working[sn]:append({ id = item.id, name = name });
                                imported = imported + 1;
                            end
                        end
                    end
                end
                local src = data.job or '?';
                print(msg(chat.success(('Pasted %d items from %s gear into %s.'):fmt(imported, src, job.name))));
            else
                print(msg(chat.error('Clipboard does not contain valid gear JSON.')));
            end
        else
            print(msg(chat.error('Clipboard is empty.')));
        end
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Paste gear loadout from clipboard JSON');
    end

    imgui.Separator();

    -- Item list: flat table with Slot | Name | ID | Give | Del
    -- Calculate total items for display
    local total_items = ui.jobgear.count_items(ui.jg_working);
    imgui.TextColored(colors.muted, ('%d items'):fmt(total_items));

    if (imgui.BeginTable(tid('##jg_items'), 5, UI_TABLE_FLAGS_SCROLL, sizes.jg_table)) then
        imgui.TableSetupColumn('Slot', ImGuiTableColumnFlags_WidthFixed, 50);
        imgui.TableSetupColumn('Name', ImGuiTableColumnFlags_WidthStretch);
        imgui.TableSetupColumn('ID',   ImGuiTableColumnFlags_WidthFixed, 55);
        imgui.TableSetupColumn('Give', ImGuiTableColumnFlags_WidthFixed, 32);
        imgui.TableSetupColumn('Del',  ImGuiTableColumnFlags_WidthFixed, 24);
        imgui.TableHeadersRow();

        local remove_slot = nil;
        local remove_idx = nil;

        for _, slot_name in ipairs(ui.jobgear.slot_order) do
            local items = ui.jg_working[slot_name] or T{};
            for i, item in ipairs(items) do
                imgui.TableNextRow();

                imgui.TableNextColumn();
                imgui.TextColored(colors.preset, slot_name);

                imgui.TableNextColumn();
                imgui.Text(item.name);

                imgui.TableNextColumn();
                imgui.TextColored(colors.muted, tostring(item.id));

                imgui.TableNextColumn();
                if (run_button('>##jg_give_' .. slot_name .. '_' .. i)) then
                    execute_command(('!additem %d 1'):fmt(item.id));
                end
                if (imgui.IsItemHovered()) then
                    imgui.SetTooltip(('!additem %d 1'):fmt(item.id));
                end

                imgui.TableNextColumn();
                imgui.PushStyleColor(ImGuiCol_Text, colors.error);
                if (imgui.Button('x##jg_del_' .. slot_name .. '_' .. i)) then
                    remove_slot = slot_name;
                    remove_idx = i;
                end
                imgui.PopStyleColor();
            end
        end

        imgui.EndTable();

        -- Process removal after table render
        if (remove_slot ~= nil and remove_idx ~= nil) then
            local items = ui.jg_working[remove_slot];
            if (items ~= nil) then
                table.remove(items, remove_idx);
            end
        end
    end

    -- Bottom bar: slot picker + add by ID + search
    imgui.Separator();

    -- Slot combo (cached)
    if (ui.combo_cache['jg_slots'] == nil) then
        local s = '';
        for _, sn in ipairs(ui.jobgear.slot_order) do
            s = s .. sn .. '\0';
        end
        ui.combo_cache['jg_slots'] = s .. '\0';
    end

    imgui.PushItemWidth(80);
    imgui.Combo('##jg_slot_pick', ui.jg_add_slot, ui.combo_cache['jg_slots']);
    imgui.PopItemWidth();

    local target_slot = ui.jobgear.slot_order[ui.jg_add_slot[1] + 1];

    -- Add by ID
    imgui.SameLine();
    imgui.PushItemWidth(80);
    imgui.InputInt('ID##jg_add_id', ui.jg_add_id, 0, 0);
    imgui.PopItemWidth();

    imgui.SameLine();
    if (imgui.Button('Add')) then
        local new_id = ui.jg_add_id[1];
        if (new_id > 0 and target_slot ~= nil) then
            local name = resolve_item_name(new_id);
            if (ui.jg_working[target_slot] == nil) then
                ui.jg_working[target_slot] = T{};
            end
            ui.jg_working[target_slot]:append({ id = new_id, name = name });
            ui.jg_add_id[1] = 0;
        end
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Add item by ID to ' .. (target_slot or '?') .. ' slot');
    end

    -- Search button
    imgui.SameLine();
    if (imgui.Button('Search')) then
        ui.jg_search_open = true;
        ui.jg_search_slot = target_slot;
        ui.jg_search_text[1] = '';
        ui.jg_search_results = T{};
        ui.focus_jg_search = true; -- focus the popup search field
        imgui.OpenPopup('Item Search##jg_popup');
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Search items by name and add to ' .. (target_slot or '?') .. ' slot');
    end

    -- Render item search popup (must be called every frame for modal to work)
    render_jg_search_popup();
end

-- Item Search View

local function render_item_search()
    -- auto-start the item cache build on entering the tab (no manual click).
    if (ui.item_cache == nil and not ui.item_cache_building) then
        ui.item_cache_building = true;
        ui.item_cache_build_pos = 0;
        ui.item_cache_count = 0;
    end

    -- Progress bar during build
    if (ui.item_cache_building) then
        local progress = ui.item_cache_build_pos / ITEM_CACHE_MAX_ID;
        imgui.ProgressBar(progress, { -1, 0 }, ('Scanning client item data... %d/%d'):fmt(ui.item_cache_build_pos, ITEM_CACHE_MAX_ID));
        imgui.TextColored(colors.muted, 'Scanning client item data...');
        return;
    end

    -- Search box (A5: focus on the first frame the box appears)
    if (ui.focus_item_search) then
        ui.focus_item_search = false;
        imgui.SetKeyboardFocusHere(0);
    end
    imgui.SetNextItemWidth(300);
    local changed = imgui.InputTextWithHint('Search##item_search', 'Search items...', ui.item_search_text, ui.item_search_text_size, ImGuiInputTextFlags_EnterReturnsTrue);
    imgui.SameLine();
    if (imgui.Button('Search') or changed) then
        local query = ui.item_search_text[1];
        if (type(query) == 'string') then
            query = query:trim('\0');
        end
        do_item_search(query);
    end

    imgui.SameLine();
    imgui.PushItemWidth(60);
    imgui.InputInt('Qty##item_qty', ui.item_search_qty, 0, 0);
    imgui.PopItemWidth();
    if (ui.item_search_qty[1] < 1) then ui.item_search_qty[1] = 1; end
    if (ui.item_search_qty[1] > 99) then ui.item_search_qty[1] = 99; end

    imgui.SameLine();
    imgui.TextColored(colors.muted, ('(%d items cached)'):fmt(ui.item_cache_count));

    -- Results (B4: distinguish "no matches" from the empty-box hint)
    if (#ui.item_search_results == 0) then
        local q = ui.item_search_text[1];
        if (type(q) == 'string') then q = q:trim('\0'); else q = ''; end
        if (q ~= '') then
            imgui.TextColored(colors.muted, ('No items match "%s".'):fmt(q));
        else
            imgui.TextColored(colors.muted, 'Type an item name and press Search or Enter.');
        end
        return;
    end

    imgui.TextColored(colors.muted, ('%d results (max 100)'):fmt(#ui.item_search_results));

    if (imgui.BeginTable(tid('##item_results'), 5, UI_TABLE_FLAGS_SCROLL, sizes.item_table)) then
        imgui.TableSetupColumn('Name',   ImGuiTableColumnFlags_WidthStretch);
        imgui.TableSetupColumn('ID',     ImGuiTableColumnFlags_WidthFixed, 55);
        imgui.TableSetupColumn('Type',   ImGuiTableColumnFlags_WidthFixed, 65);
        imgui.TableSetupColumn('Stack',  ImGuiTableColumnFlags_WidthFixed, 40);
        imgui.TableSetupColumn('Give',   ImGuiTableColumnFlags_WidthFixed, 40);
        imgui.TableHeadersRow();

        for i, item in ipairs(ui.item_search_results) do
            imgui.TableNextRow();

            imgui.TableNextColumn();
            imgui.Text(item.name);
            -- tooltip for clipped item names.
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip((item.name or ''):gsub('%%', '%%%%'));
            end
            -- right-click menu (Copy '!additem id qty' / Copy ID).
            if (imgui.BeginPopupContextItem('ctxitem_' .. i)) then
                if (imgui.Selectable('Copy !additem command')) then
                    clipboard_set(('!additem %d %d'):fmt(item.id, ui.item_search_qty[1]));
                end
                if (imgui.Selectable('Copy ID')) then clipboard_set(tostring(item.id)); end
                imgui.EndPopup();
            end

            imgui.TableNextColumn();
            imgui.TextColored(colors.muted, tostring(item.id));

            imgui.TableNextColumn();
            -- color-code the Type column.
            local type_name = item_type_names[item.type] or tostring(item.type);
            local tcol = item_type_colors[item.type];
            if (tcol ~= nil) then imgui.TextColored(tcol, type_name); else imgui.Text(type_name); end

            imgui.TableNextColumn();
            imgui.Text(tostring(item.stack));

            imgui.TableNextColumn();
            if (run_button('>##isr_' .. i)) then
                execute_command(('!additem %d %d'):fmt(item.id, ui.item_search_qty[1]));
            end
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip(('!additem %d %d'):fmt(item.id, ui.item_search_qty[1]));
            end
        end

        imgui.EndTable();
    end
end

-- Status Bar

local STATUS_LAST_MAX = 40; -- max display chars for the 'Last:' command

local function render_status_bar()
    imgui.Separator();

    -- Last command (D3: truncate with ellipsis, full text in tooltip)
    if (ui.last_cmd ~= '') then
        imgui.TextColored(colors.muted, 'Last:');
        imgui.SameLine();
        local shown = ui.last_cmd;
        if (#shown > STATUS_LAST_MAX) then
            shown = shown:sub(1, STATUS_LAST_MAX - 3) .. '...';
        end
        imgui.Text(shown);
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip((ui.last_cmd or ''):gsub('%%', '%%%%'));
        end
    else
        imgui.TextColored(colors.muted, 'Ready');
    end

    -- Show queue progress here only outside the Presets tab, which has its own progress bar.
    if (ui.current_view ~= ui.VIEW_PRESETS and #ui.cmd_queue > 0) then
        local progress = ui.queue_total - #ui.cmd_queue;
        imgui.SameLine();
        imgui.TextColored(colors.running, ('(%d/%d running)'):fmt(progress, ui.queue_total));
        imgui.SameLine();
        imgui.PushStyleColor(ImGuiCol_Button, btn_colors.stop);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, btn_colors.stop_hover);
        if (imgui.Button('Stop')) then
            ui.stop_queue();
        end
        imgui.PopStyleColor(2);
    end

    -- Reset UI button: right-anchored relative to the window, independent of the
    -- 'Last:' text length.
    imgui.SameLine(imgui.GetWindowWidth() - 90);
    imgui.PushStyleColor(ImGuiCol_Button, btn_colors.reset);
    if (imgui.Button('Reset UI')) then
        ui.reset_pending = true;
    end
    imgui.PopStyleColor();
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Reset window size, position, and column widths to defaults.');
    end
end

-- Main Render

function ui.render()
    if (not ui.is_open[1]) then return; end

    -- Don't render until character is in a zone (not character select screen)
    local player = GetPlayerEntity();
    if (player == nil) then return; end
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return; end
    local party = mem:GetParty();
    if (party == nil) then return; end
    if ((party:GetMemberZone(0) or 0) == 0) then return; end

    -- Handle pending UI reset: change table salt so ImGui forgets all saved column widths
    if (ui.reset_pending) then
        ui.reset_pending = false;
        ui.table_salt = ui.table_salt + 1;
        ui.current_view = ui.VIEW_CATEGORIES;
        ui.view_force = true; -- force the TabBar back to Categories
        ui.selected_category = 0;
        -- Force window back to default size/position
        imgui.SetNextWindowSize(sizes.window, ImGuiCond_Always);
        imgui.SetNextWindowPos(sizes.window_pos, ImGuiCond_Always);
        print(msg(chat.success('UI reset to defaults.')));
    end
    imgui.SetNextWindowSize(sizes.window, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints(sizes.window_min, sizes.window_max);

    if (imgui.Begin('GM Tools', ui.is_open, ImGuiWindowFlags_None)) then

        -- Programmatic view changes force the matching tab for one frame.
        if (imgui.BeginTabBar('##gmviews', ImGuiTabBarFlags_None)) then
            for _, t in ipairs(view_tabs) do
                local flags = ImGuiTabItemFlags_None;
                if (ui.view_force and ui.current_view == t[2]) then
                    flags = ImGuiTabItemFlags_SetSelected;
                end
                if (imgui.BeginTabItem(t[1], nil, flags)) then
                    ui.current_view = t[2];
                    imgui.EndTabItem();
                end
            end
            ui.view_force = false;
            imgui.EndTabBar();
        end

        -- on a tab switch, arm the one-shot focus flag for search-bearing tabs.
        if (ui.prev_view ~= ui.current_view) then
            ui.prev_view = ui.current_view;
            if (ui.current_view == ui.VIEW_ITEM_SEARCH) then
                ui.focus_item_search = true;
            elseif (ui.current_view == ui.VIEW_HISTORY) then
                ui.focus_history = true;
            end
        end

        -- Disable only queue-mutating controls while a preset runs.
        if (ui.current_view == ui.VIEW_CATEGORIES) then
            -- Sidebar + Detail panel layout
            render_sidebar();
            imgui.SameLine();

            imgui.BeginChild('##detail', sizes.panel, ImGuiChildFlags_Borders);
                local cat_idx = ui.selected_category + 1;
                local cat = ui.commands.categories[cat_idx];
                if (cat ~= nil) then
                    -- Header: category name + GM Level filter (D1 moved here, D4 width).
                    imgui.TextColored(colors.header, cat.name);
                    imgui.SameLine();
                    imgui.SetNextItemWidth(160);
                    if (imgui.Combo('GM Lvl##gmlvl', ui.gm_level, ui.gm_level_names)) then
                        ui.settings_dirty = true;
                    end
                    imgui.Separator();

                    -- global command search across all categories.
                    imgui.SetNextItemWidth(220);
                    imgui.InputTextWithHint('##cmdsearch', 'Search commands...', ui.cmd_search, ui.cmd_search_size);
                    local cq = ui.cmd_search[1];
                    if (type(cq) == 'string') then cq = cq:trim('\0'); else cq = ''; end
                    if (cq ~= '') then
                        render_command_search_table(get_command_search_results(cq:lower()));
                    else
                        render_command_table(cat_idx, cat);
                    end
                else
                    imgui.TextColored(colors.muted, 'Select a category from the sidebar.');
                end
            imgui.EndChild();

        elseif (ui.current_view == ui.VIEW_FAVORITES) then
            imgui.BeginChild('##fav_panel', sizes.panel, ImGuiChildFlags_Borders);
                render_favorites();
            imgui.EndChild();

        elseif (ui.current_view == ui.VIEW_PRESETS) then
            imgui.BeginChild('##preset_panel', sizes.panel, ImGuiChildFlags_Borders);
                render_presets();
            imgui.EndChild();

        elseif (ui.current_view == ui.VIEW_JOBGEAR) then
            imgui.BeginChild('##jobgear_panel', sizes.panel, ImGuiChildFlags_Borders);
                render_jobgear();
            imgui.EndChild();

        elseif (ui.current_view == ui.VIEW_ITEM_SEARCH) then
            imgui.BeginChild('##search_panel', sizes.panel, ImGuiChildFlags_Borders);
                render_item_search();
            imgui.EndChild();

        elseif (ui.current_view == ui.VIEW_HISTORY) then
            imgui.BeginChild('##hist_panel', sizes.panel, ImGuiChildFlags_Borders);
                render_history();
            imgui.EndChild();
        end

        render_status_bar();
    end
    imgui.End();
end

return ui;
