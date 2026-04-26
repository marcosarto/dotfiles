local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local app_icons = require("helpers.app_icons")

local spaces = {}       -- workspace_name -> space item
local paddings = {}     -- workspace_name -> padding item
local popups = {}       -- workspace_name -> popup item
local known_workspaces = {} -- set of known workspace names

local function split(str, sep)
    local result = {}
    for each in str:gmatch("([^" .. sep .. "]+)") do
        table.insert(result, each)
    end
    return result
end

local function brighten(color, factor)
    local a = (color >> 24) & 0xff
    local r = math.min(255, math.floor(((color >> 16) & 0xff) * factor))
    local g = math.min(255, math.floor(((color >> 8) & 0xff) * factor))
    local b = math.min(255, math.floor((color & 0xff) * factor))
    return (a << 24) | (r << 16) | (g << 8) | b
end

-- Update app icons for a workspace
local function update_app_icons(ws)
    local space = spaces[ws]
    if not space then return end
    sbar.exec("aerospace list-windows --workspace " .. ws .. " --format '%{app-name}' --json", function(apps)
        local icon_line = ""
        local no_app = true
        for _, app in ipairs(apps) do
            no_app = false
            local lookup = app_icons[app["app-name"]]
            icon_line = icon_line .. " " .. (lookup or app_icons["default"])
        end
        if no_app then icon_line = " —" end
        sbar.animate("tanh", 10, function()
            space:set({ label = icon_line })
        end)
    end)
end

-- Async reorder + color: runs periodically
local function reorder_and_color(focused)
    sbar.exec("aerospace list-workspaces --all", function(output)
        local ordered = {}
        for ws in output:gmatch("([^\n]+)") do
            if spaces[ws] then
                table.insert(ordered, "item." .. ws)
                table.insert(ordered, "item." .. ws .. "padding")
            end
        end
        if #ordered > 0 then
            sbar.exec("sketchybar --reorder " .. table.concat(ordered, " "))
        end
    end)
    sbar.exec("aerospace list-monitors | awk '{print $1}'", function(monitor_output)
        local monitors = {}
        for line in monitor_output:gmatch("([^\n]+)") do
            table.insert(monitors, line)
        end
        for _, mon in ipairs(monitors) do
            sbar.exec("aerospace list-workspaces --monitor " .. mon, function(ws_output)
                local mon_color = colors.monitor[tonumber(mon)] or colors.monitor[1]
                local bright = brighten(mon_color, 1.4)
                for ws in ws_output:gmatch("([^\n]+)") do
                    local space = spaces[ws]
                    if space then
                        local selected = (ws == focused)
                        space:set({
                            icon = { color = mon_color, highlight_color = bright, highlight = selected },
                            label = { color = mon_color, highlight_color = bright, highlight = selected },
                            background = { border_color = selected and bright or mon_color }
                        })
                    end
                end
            end)
        end
    end)
end

-- Create a workspace item
local function add_workspace(ws)
    if spaces[ws] then return end

    local space = sbar.add("item", "item." .. ws, {
        icon = {
            font = { family = settings.font.numbers },
            string = ws,
            padding_left = settings.items.padding.left,
            padding_right = settings.items.padding.left / 2,
            color = colors.monitor[1],
            highlight_color = settings.items.highlight_color(0),
        },
        label = {
            padding_right = settings.items.padding.right,
            color = colors.monitor[1],
            highlight_color = settings.items.highlight_color(0),
            font = settings.icons,
            y_offset = -1,
        },
        padding_right = 1,
        padding_left = 1,
        background = {
            color = settings.items.colors.background,
            border_width = 1,
            height = settings.items.height,
            border_color = colors.monitor[1],
        },
        popup = { background = { border_width = 5, border_color = colors.black } }
    })

    spaces[ws] = space
    known_workspaces[ws] = true

    paddings[ws] = sbar.add("item", "item." .. ws .. "padding", {
        script = "",
        width = settings.items.gap
    })

    popups[ws] = sbar.add("item", {
        position = "popup." .. space.name,
        padding_left = 5,
        padding_right = 0,
        background = { drawing = true, image = { corner_radius = 9, scale = 0.2 } }
    })

    space:subscribe("mouse.clicked", function(env)
        local SID = split(env.NAME, ".")[2]
        if env.BUTTON == "other" then
            popups[ws]:set({ background = { image = "item." .. SID } })
            space:set({ popup = { drawing = "toggle" } })
        else
            sbar.exec("aerospace workspace " .. SID)
        end
    end)

    space:subscribe("mouse.exited", function(_)
        space:set({ popup = { drawing = false } })
    end)

    update_app_icons(ws)
end

-- Remove a workspace item
local function remove_workspace(ws)
    if spaces[ws] then sbar.remove(spaces[ws]) end
    if paddings[ws] then sbar.remove(paddings[ws]) end
    if popups[ws] then sbar.remove(popups[ws]) end
    spaces[ws] = nil
    paddings[ws] = nil
    popups[ws] = nil
    known_workspaces[ws] = nil
end

-- Sync: add new workspaces, remove gone ones
local function sync(focused)
    sbar.exec("aerospace list-workspaces --all", function(output)
        local current_set = {}
        local current = {}
        for ws in output:gmatch("([^\n]+)") do
            table.insert(current, ws)
            current_set[ws] = true
        end

        for ws, _ in pairs(known_workspaces) do
            if not current_set[ws] then
                remove_workspace(ws)
            end
        end

        for _, ws in ipairs(current) do
            add_workspace(ws)
        end

        -- Update highlight
        for ws, _ in pairs(known_workspaces) do
            local space = spaces[ws]
            if space then
                local selected = (ws == focused)
                space:set({
                    icon = { highlight = selected },
                    label = { highlight = selected },
                })
            end
        end
    end)
end

-- Initial setup (blocking is fine at startup)
local initial_workspaces = get_workspaces()
local focused = get_current_workspace()
for _, ws in ipairs(initial_workspaces) do
    add_workspace(ws)
end

-- Observer for all events
local observer = sbar.add("item", {
    drawing = false,
    updates = true,
    update_freq = 30, -- periodic reorder every 30s
})

observer:subscribe("aerospace_workspace_change", function(env)
    sync(env.FOCUSED_WORKSPACE)
    for ws, _ in pairs(known_workspaces) do
        update_app_icons(ws)
    end
end)

observer:subscribe("aerospace_focus_change", function(env)
    for ws, _ in pairs(known_workspaces) do
        update_app_icons(ws)
    end
end)

observer:subscribe("routine", function(_)
    sbar.exec("aerospace list-workspaces --focused", function(focused_output)
        local focused = focused_output:match("([^\n]+)")
        reorder_and_color(focused)
    end)
end)

-- Initial colors + order
reorder_and_color(focused)
