--[[
    GM Tools v1.0.0 - GM Command Helper for Ashita v4

    Provides an ImGui GUI for executing LandSandBoat GM commands.

    Commands:
        /gm              - Toggle the GM Tools window
        /gm help         - Show available subcommands
        /gm preset <n>   - Run a preset by name
        /gm stop         - Stop a running preset
        /gm resetui      - Reset UI layout and column widths
        /gm delay <sec>  - Set preset command delay (default 1.5s)
        /gm gear <job>   - Give gear loadout for a job (e.g., /gm gear WAR)
        /gm export <job> - Export gear loadout to clipboard as JSON
        /gm import       - Import gear loadout from clipboard into current job
        /gm search <item> - Search items by name (e.g., /gm search mythic)

    Author: SQLCommit
    Version: 1.0.0
]]--

addon.name      = 'gmtools';
addon.author    = 'SQLCommit';
addon.version   = '1.0.0';
addon.desc      = 'GM command helper with ImGui UI for LandSandBoat servers.';
addon.link      = 'https://github.com/SQLCommit/gmtools';

require 'common';

local chat     = require 'chat';
local settings = require 'settings';
local ui       = require 'ui';
local db       = require 'db';
local commands = require 'commands';
local presets  = require 'presets';
local jobgear  = require 'jobgear';

-------------------------------------------------------------------------------
-- Default Settings (saved per-character via Ashita settings)
-------------------------------------------------------------------------------
local default_settings = T{
    queue_delay = 1.5,
    gm_level    = 5,
};

-------------------------------------------------------------------------------
-- Helper: Print help information
-------------------------------------------------------------------------------

local function print_help()
    print(chat.header(addon.name):append(chat.message('Available commands:')));
    local cmds = T{
        { '/gm',                'Toggle the GM Tools window.' },
        { '/gm help',           'Show this help message.' },
        { '/gm preset <name>',  'Run a preset by name (e.g., /gm preset full unlock).' },
        { '/gm stop',           'Stop a running preset mid-execution.' },
        { '/gm resetui',       'Reset window size, position, and column widths.' },
        { '/gm delay <seconds>', 'Set delay between preset commands (default 1.5s).' },
        { '/gm gear <job>',     'Give gear loadout for a job (e.g., /gm gear WAR).' },
        { '/gm export <job>',   'Export gear loadout to clipboard as JSON (e.g., /gm export WAR).' },
        { '/gm import',         'Import gear from clipboard into currently selected job.' },
        { '/gm search <item>',  'Search items by name (e.g., /gm search sword).' },
    };
    cmds:ieach(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);

    -- List available presets
    print(chat.header(addon.name):append(chat.message('Built-in presets:')));
    for _, p in ipairs(presets.defaults) do
        print(chat.header(addon.name):append(chat.success('  ' .. p.name)):append(chat.message(' - ' .. p.desc)));
    end

    -- List available jobs
    print(chat.header(addon.name):append(chat.message('Available jobs for /gm gear:')));
    local job_names = T{};
    for _, j in ipairs(jobgear.jobs) do
        job_names:append(j.name);
    end
    print(chat.header(addon.name):append(chat.success('  ' .. job_names:concat(', '))));

    print(chat.header(addon.name):append(chat.message('Current delay: ')):append(chat.success(('%.1fs'):fmt(ui.queue_delay[1]))));
    print(chat.header(addon.name):append(chat.color1(6, 'Note: Window renders inside the game. Use windowed mode to move FFXI to another monitor.')));
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

ashita.events.register('load', 'gmtools_load', function ()
    -- Load per-character settings
    local s = settings.load(default_settings);

    -- Initialize database (store in addon's config directory)
    local config_path = AshitaCore:GetInstallPath() .. '\\config\\addons\\gmtools';

    -- Ensure config directory exists
    ashita.fs.create_directory(config_path);

    db.init(config_path);
    ui.init(commands, presets, db, jobgear, s);

    print(chat.header(addon.name):append(chat.message('Loaded. Use ')):append(chat.success('/gm')):append(chat.message(' to toggle window.')));
end);

ashita.events.register('unload', 'gmtools_unload', function ()
    ui.sync_settings();
    settings.save();
    db.close();
end);

ashita.events.register('command', 'gmtools_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/gm')) then
        return;
    end

    -- Block all /gm commands
    e.blocked = true;

    -- /gm - Toggle window
    if (#args == 1) then
        ui.is_open[1] = not ui.is_open[1];
        return;
    end

    -- /gm help
    if (args[2]:any('help')) then
        print_help();
        return;
    end

    -- /gm stop
    if (args[2]:any('stop')) then
        ui.stop_queue();
        return;
    end

    -- /gm resetui
    if (args[2]:any('resetui', 'reset')) then
        ui.reset_pending = true;
        ui.is_open[1] = true;
        return;
    end

    -- /gm preset <name>
    if (args[2]:any('preset') and #args >= 3) then
        local preset_name = args:concat(' ', 3);
        ui.run_preset_by_name(preset_name);
        return;
    end

    -- /gm gear <job>
    if (args[2]:any('gear') and #args >= 3) then
        local job_name = args[3]:upper();
        for _, job in ipairs(jobgear.jobs) do
            if (job.name == job_name) then
                -- Use DB override if saved, otherwise use defaults
                local slots;
                if (db.has_job_gear_override(job.name)) then
                    local db_slots = db.get_job_gear(job.name);
                    slots = {};
                    for _, sn in ipairs(jobgear.slot_order) do
                        slots[sn] = db_slots[sn] or T{};
                    end
                else
                    slots = job.slots;
                end
                local cmds = jobgear.build_commands(slots);
                ui.cmd_queue = T{};
                for _, cmd in ipairs(cmds) do
                    ui.cmd_queue:append(cmd);
                end
                ui.queue_total = #ui.cmd_queue;
                ui.queue_timer = os.clock() - ui.queue_delay[1];
                local item_count = jobgear.count_items(slots);
                print(chat.header(addon.name):append(chat.message('Giving ' .. job.name .. ' gear: '))
                    :append(chat.success(('%d items, %.1fs delay'):fmt(item_count, ui.queue_delay[1]))));
                return;
            end
        end
        print(chat.header(addon.name):append(chat.error('Unknown job: ' .. args[3] .. '. Use 3-letter abbreviation (WAR, MNK, etc.).')));
        return;
    end

    -- /gm export <job>
    if (args[2]:any('export') and #args >= 3) then
        local job_name = args[3]:upper();
        ui.export_job_gear(job_name);
        return;
    end

    -- /gm import
    if (args[2]:any('import')) then
        ui.import_job_gear();
        return;
    end

    -- /gm search <item name>
    if (args[2]:any('search') and #args >= 3) then
        local search_query = args:concat(' ', 3);
        ui.start_item_search(search_query);
        return;
    end

    -- /gm delay <seconds>
    if (args[2]:any('delay') and #args >= 3) then
        local val = tonumber(args[3]);
        if (val ~= nil and val >= 0.1 and val <= 10.0) then
            ui.queue_delay[1] = val;
            ui.sync_settings();
            settings.save();
            print(chat.header(addon.name):append(chat.message('Preset delay set to ')):append(chat.success(('%.1fs'):fmt(val))));
        else
            print(chat.header(addon.name):append(chat.error('Delay must be between 0.1 and 10.0 seconds.')));
        end
        return;
    end

    -- Unknown subcommand
    print(chat.header(addon.name):append(chat.error('Unknown command. Use /gm help for usage.')));
end);

ashita.events.register('d3d_present', 'gmtools_present', function ()
    -- Save settings if UI flagged a change
    if (ui.settings_dirty) then
        ui.settings_dirty = false;
        ui.sync_settings();
        settings.save();
    end

    ui.process_queue();
    ui.render();
end);

-------------------------------------------------------------------------------
-- Event: Settings changed externally
-------------------------------------------------------------------------------
settings.register('settings', 'gmtools_settings_update', function(s)
    if (s ~= nil) then
        ui.apply_settings(s);
    end
end);
