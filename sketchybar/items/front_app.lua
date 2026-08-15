local colors = require("colors")
local settings = require("settings")

local front_app = sbar.add("item", "front_app", {
    display = "active",
    icon = {
        drawing = false
    },
    label = {
        font = {
            style = settings.font.style_map["Bold"],
            size = 13.0
        }
    },
    updates = true
})

front_app:subscribe("front_app_switched", function(env)
    front_app:set({
        label = {
            string = env.INFO
        }
    })
end)

front_app:subscribe("aerospace_workspace_change", function(env)
    local current = front_app:query()
    local app_name = current.label.value or ""
    local ws = env.FOCUSED_WORKSPACE or "?"
    front_app:set({
        label = {
            string = "[" .. ws .. "] " .. app_name
        }
    })
end)

front_app:subscribe("mouse.clicked", function(env)
    sbar.trigger("swap_menus_and_spaces")
end)
