local colors = require("colors")
local icons = require("icons")

-- Right-position items render right-to-left
-- Visual order: title | ⏮ | ⏸ | ⏭
-- Add order (reverse): back, play/pause, fwd, title

local media_fwd = sbar.add("item", "media.fwd", {
    position = "right",
    icon = { string = icons.media.forward, padding_left = 2, padding_right = 6 },
    label = { drawing = false },
    drawing = false,
    click_script = "nowplaying-cli next",
})

local media = sbar.add("item", "media", {
    position = "right",
    icon = { string = icons.media.play_pause, padding_left = 4, padding_right = 4 },
    label = { drawing = false },
    drawing = false,
    click_script = "nowplaying-cli togglePlayPause",
})

local media_back = sbar.add("item", "media.back", {
    position = "right",
    icon = { string = icons.media.back, padding_left = 6, padding_right = 2 },
    label = { drawing = false },
    drawing = false,
    click_script = "nowplaying-cli previous",
})

local media_title = sbar.add("item", "media.title", {
    position = "right",
    icon = { drawing = false },
    label = { string = "", max_chars = 30, padding_left = 8, padding_right = 4 },
    scroll_texts = false,
    update_freq = 5,
    updates = "on",
    drawing = false,
})

media_title:subscribe({"routine", "forced"}, function(_)
    sbar.exec("nowplaying-cli get playbackRate title artist", function(result)
        local rate, title, artist = result:match("([^\n]*)\n([^\n]*)\n([^\n]*)")
        if not title or title == "null" or title == "" then
            media:set({ drawing = false })
            media_back:set({ drawing = false })
            media_fwd:set({ drawing = false })
            media_title:set({ drawing = false })
            return
        end
        local playing = (rate and rate ~= "0" and rate ~= "null")
        local icon = playing and "􀊆" or "􀊄"
        local label = title
        if artist and artist ~= "null" and artist ~= "" then
            label = title .. " — " .. artist
        end
        media:set({ drawing = true, icon = { string = icon } })
        media_back:set({ drawing = true })
        media_fwd:set({ drawing = true })
        media_title:set({ drawing = true, label = { string = label } })
    end)
end)
