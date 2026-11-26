-- Boundary: fork-only settings menu items.
--
-- Responsibility: add this fork's options to the menu built by
-- suwayomi/plugin/settings_controller without editing upstream's menu table.
-- Owned state: none.
-- Dependencies: suwayomi/settings and suwayomi/i18n.
-- External data: none.

local I18n = require("suwayomi/i18n")

-- Resolved per call so the menu always uses the loaded settings module.
local function settings() return require("suwayomi/settings") end

local ForkSettings = {}

local function findByText(items, text)
    for index, item in ipairs(type(items) == "table" and items or {}) do
        if type(item) == "table" and item.text == text then return item, index end
    end
end

local function resizePagesItem(controller)
    return {
        text = I18n.t("Resize pages to fit screen"),
        help_text = I18n.t("Shrinks large pages to your screen size while downloading. Saves storage and makes page turns faster, but each page takes longer to download. Very large pages are kept as they are. When off, chapters already downloaded on the server are fetched in one go instead. Applies to new downloads only."),
        checked_func = function()
            return settings():loadResizePagesToScreen()
        end,
        keep_menu_open = true,
        callback = function()
            local saved, err = settings():saveResizePagesToScreen(not settings():loadResizePagesToScreen())
            if saved == nil then
                controller:showMessage(err or I18n.t("Failed to save settings."))
            end
        end,
    }
end

-- Inserts fork items into `menu` in place. A missing Downloads menu is left
-- alone rather than guessed at.
function ForkSettings.extend(controller, menu)
    local root = type(menu) == "table" and (menu.sub_item_table or menu) or nil
    local downloads = findByText(root, I18n.t("Downloads"))
    if not downloads or type(downloads.sub_item_table) ~= "table" then return menu end
    local items = downloads.sub_item_table
    local _, help_index = findByText(items, I18n.t("Download help"))
    table.insert(items, help_index or (#items + 1), resizePagesItem(controller))
    return menu
end

return ForkSettings
