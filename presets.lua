--[[
    GM Tools v1.0.0 - Preset Definitions
    Quick-setup presets that execute multiple GM commands in sequence.
]]--

require 'common';

local presets = {};

presets.defaults = T{
    {
        name = 'Max Character',
        desc = 'Level 99, master job, all skills capped',
        commands = T{
            '!setplayerlevel 99',
            '!masterjob',
            '!capallskills',
        },
    },
    {
        name = 'All Unlocks',
        desc = 'All spells, trusts, weapon skills, maps, mounts, attachments',
        commands = T{
            '!addallspells',
            '!addalltrusts',
            '!addallweaponskills',
            '!addallmaps',
            '!addallmounts',
            '!addallattachments',
            '!addallmonstrosity',
            '!addallatma',
        },
    },
    {
        name = 'Rich Character',
        desc = '10M gil, max inventory size',
        commands = T{
            '!setgil 10000000',
            '!setbag 80',
        },
    },
    {
        name = 'God Mode',
        desc = 'Invincibility + fast speed + wallhack',
        commands = T{
            '!godmode',
            '!speed 100',
            '!wallhack',
        },
    },
    {
        name = 'Full Unlock',
        desc = 'Max level + all unlocks + subjob/merit/JP menus + rich',
        commands = T{
            '!setplayerlevel 99',
            '!masterjob',
            '!capallskills',
            -- Enable subjob system + merit/JP menus
            '!exec player:unlockJob(0)',
            '!changesjob WAR',
            '!addkeyitem 606',
            '!addkeyitem 2544',
            -- All content unlocks
            '!addallspells',
            '!addalltrusts',
            '!addallweaponskills',
            '!addallmaps',
            '!addallmounts',
            '!addallattachments',
            '!addallmonstrosity',
            '!addallatma',
            '!setgil 10000000',
            '!setbag 80',
        },
    },
    {
        name = 'Reset Movement',
        desc = 'Normal speed, disable wallhack',
        commands = T{
            '!speed 0',
            '!wallhack',
        },
    },
    {
        name = 'Combat Ready',
        desc = 'Full HP/MP, 3000 TP, god mode',
        commands = T{
            '!hp 9999',
            '!mp 9999',
            '!tp 3000',
            '!godmode',
        },
    },
    {
        name = 'GM Setup',
        desc = 'Toggle GM flag, hide, fast speed',
        commands = T{
            '!togglegm',
            '!hide',
            '!speed 50',
        },
    },

    -- Progression Unlock Presets
    -- !changejob <job> <level> <master> unlocks the job, sets its level, and masters it in one command.
    -- !changesjob <job> sets a specific job as current subjob (sets jobs.unlocked bit for that job).
    -- !exec player:unlockJob(0) sets bit 0 = subjob SYSTEM unlocked (required for Mog House menu).
    -- !addkeyitem 606  = LIMIT_BREAKER (required for merit points menu, needs level 75+).
    -- !addkeyitem 2544 = JOB_BREAKER (required for job points menu, needs level 99 + mastered).

    {
        name = 'Unlock All Jobs',
        desc = 'Unlock, level 99, and master all 22 jobs + enable subjob + merit/JP menus',
        commands = T{
            -- Each !changejob <JOB> 99 1 = unlock + set level 99 + master job points
            '!changejob WAR 99 1',
            '!changejob MNK 99 1',
            '!changejob WHM 99 1',
            '!changejob BLM 99 1',
            '!changejob RDM 99 1',
            '!changejob THF 99 1',
            '!changejob PLD 99 1',
            '!changejob DRK 99 1',
            '!changejob BST 99 1',
            '!changejob BRD 99 1',
            '!changejob RNG 99 1',
            '!changejob SAM 99 1',
            '!changejob NIN 99 1',
            '!changejob DRG 99 1',
            '!changejob SMN 99 1',
            '!changejob BLU 99 1',
            '!changejob COR 99 1',
            '!changejob PUP 99 1',
            '!changejob DNC 99 1',
            '!changejob SCH 99 1',
            '!changejob GEO 99 1',
            '!changejob RUN 99 1',
            -- Return to WAR as final job
            '!changejob WAR 99 1',
            '!capallskills',
            -- Enable subjob system: bit 0 = system unlock, !changesjob = set current subjob
            '!exec player:unlockJob(0)',
            '!changesjob WAR',
            -- Enable merit points menu (requires LIMIT_BREAKER key item + level 75+)
            '!addkeyitem 606',
            -- Enable job points menu (requires JOB_BREAKER key item + level 99 + mastered)
            '!addkeyitem 2544',
        },
    },
    {
        name = 'Complete Progression',
        desc = 'Enable subjob + merit/JP menus, mark quest log (subjob, LB1-10, job unlocks)',
        commands = T{
            -- Enable subjob system: bit 0 = system unlock, !changesjob = set current subjob
            '!exec player:unlockJob(0)',
            '!changesjob WAR',
            -- Enable merit points menu (LIMIT_BREAKER) and job points menu (JOB_BREAKER)
            '!addkeyitem 606',
            '!addkeyitem 2544',
            -- Mark subjob unlock quest complete in quest log
            '!completequest 4 24',
            -- Limit Breaks LB1-LB10 (JEUNO log 3, quests 128-137)
            '!completequest 3 128',
            '!completequest 3 129',
            '!completequest 3 130',
            '!completequest 3 131',
            '!completequest 3 132',
            '!completequest 3 133',
            '!completequest 3 134',
            '!completequest 3 135',
            '!completequest 3 136',
            '!completequest 3 137',
            -- Job unlock quests (marks quest log, actual unlock done via !changejob)
            '!completequest 0 29',   -- PLD: A Knight's Test (SANDORIA)
            '!completequest 1 28',   -- DRK: Blade of Darkness (BASTOK)
            '!completequest 3 19',   -- BST: Path of the Beastmaster (JEUNO)
            '!completequest 3 20',   -- BRD: Path of the Bard (JEUNO)
            '!completequest 2 31',   -- RNG: The Fanged One (WINDURST)
            '!completequest 5 129',  -- SAM: Forge Your Destiny (OUTLANDS)
            '!completequest 1 60',   -- NIN: Ayame and Kaede (BASTOK)
            '!completequest 0 93',   -- DRG: The Holy Crest (SANDORIA)
            '!completequest 2 75',   -- SMN: I Can Hear a Rainbow (WINDURST)
            '!completequest 6 5',    -- BLU: An Empty Vessel (AHT_URHGAN)
            '!completequest 6 6',    -- COR: Luck of the Draw (AHT_URHGAN)
            '!completequest 6 7',    -- PUP: No Strings Attached (AHT_URHGAN)
            '!completequest 3 95',   -- DNC: Lakeside Minuet (JEUNO)
            '!completequest 7 6',    -- SCH: A Little Knowledge (CRYSTAL_WAR)
            '!completequest 9 118',  -- GEO: Dances with Luopans (ADOULIN)
            '!completequest 9 119',  -- RUN: Children of the Rune (ADOULIN)
        },
    },
    {
        name = 'Ultimate Dev Setup',
        desc = 'Everything: all jobs 99+mastered, subjob, merit/JP, all unlocks, rich',
        commands = T{
            -- 1. Unlock, level 99, and master all 22 jobs
            '!changejob WAR 99 1',
            '!changejob MNK 99 1',
            '!changejob WHM 99 1',
            '!changejob BLM 99 1',
            '!changejob RDM 99 1',
            '!changejob THF 99 1',
            '!changejob PLD 99 1',
            '!changejob DRK 99 1',
            '!changejob BST 99 1',
            '!changejob BRD 99 1',
            '!changejob RNG 99 1',
            '!changejob SAM 99 1',
            '!changejob NIN 99 1',
            '!changejob DRG 99 1',
            '!changejob SMN 99 1',
            '!changejob BLU 99 1',
            '!changejob COR 99 1',
            '!changejob PUP 99 1',
            '!changejob DNC 99 1',
            '!changejob SCH 99 1',
            '!changejob GEO 99 1',
            '!changejob RUN 99 1',
            -- Return to WAR as final job
            '!changejob WAR 99 1',
            '!capallskills',
            '!setmerits 30',
            -- 2. Enable subjob system (bit 0 = system, !changesjob = set current sub)
            '!exec player:unlockJob(0)',
            '!changesjob WAR',
            -- 3. Enable merit points (LIMIT_BREAKER) and job points (JOB_BREAKER) menus
            '!addkeyitem 606',
            '!addkeyitem 2544',
            -- 4. All content unlocks
            '!addallspells',
            '!addalltrusts',
            '!addallweaponskills',
            '!addallmaps',
            '!addallmounts',
            '!addallattachments',
            '!addallmonstrosity',
            '!addallatma',
            -- 5. Gil and inventory
            '!setgil 10000000',
            '!setbag 80',
            -- 6. Complete subjob quest in quest log
            '!completequest 4 24',
            -- 7. Complete all limit breaks
            '!completequest 3 128',
            '!completequest 3 129',
            '!completequest 3 130',
            '!completequest 3 131',
            '!completequest 3 132',
            '!completequest 3 133',
            '!completequest 3 134',
            '!completequest 3 135',
            '!completequest 3 136',
            '!completequest 3 137',
            -- 8. Complete job unlock quests (for quest log)
            '!completequest 0 29',   -- PLD
            '!completequest 1 28',   -- DRK
            '!completequest 3 19',   -- BST
            '!completequest 3 20',   -- BRD
            '!completequest 2 31',   -- RNG
            '!completequest 5 129',  -- SAM
            '!completequest 1 60',   -- NIN
            '!completequest 0 93',   -- DRG
            '!completequest 2 75',   -- SMN
            '!completequest 6 5',    -- BLU
            '!completequest 6 6',    -- COR
            '!completequest 6 7',    -- PUP
            '!completequest 3 95',   -- DNC
            '!completequest 7 6',    -- SCH
            '!completequest 9 118',  -- GEO
            '!completequest 9 119',  -- RUN
        },
    },
};

return presets;
