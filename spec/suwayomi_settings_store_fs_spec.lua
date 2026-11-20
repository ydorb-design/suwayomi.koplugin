package.path = "?.lua;" .. package.path

-- KOReader ships LuaFileSystem as libs/libkoreader-lfs, not "lfs". The default
-- settings IO adapter must create and detect folders through suwayomi/fs.
describe("suwayomi/settings/store default folder IO", function()
    local saved_lfs, saved_preload, saved_fs, saved_store, root

    before_each(function()
        saved_lfs, saved_preload = package.loaded.lfs, package.preload.lfs
        saved_fs, saved_store = package.loaded["suwayomi/fs"], package.loaded["suwayomi/settings/store"]
        local real_lfs = saved_lfs or require("lfs")
        package.loaded.lfs = nil
        package.preload.lfs = function() error("plain lfs is not available in KOReader") end
        package.loaded["libs/libkoreader-lfs"] = real_lfs
        package.loaded["suwayomi/fs"] = nil
        package.loaded["suwayomi/settings/store"] = nil
        root = os.tmpname()
        os.remove(root)
        assert(real_lfs.mkdir(root))
    end)

    after_each(function()
        os.execute("rm -rf '" .. root .. "'")
        package.loaded.lfs, package.preload.lfs = saved_lfs, saved_preload
        package.loaded["libs/libkoreader-lfs"] = nil
        package.loaded["suwayomi/fs"], package.loaded["suwayomi/settings/store"] = saved_fs, saved_store
    end)

    it("creates and detects folders with KOReader's filesystem module", function()
        local SettingsStore = require("suwayomi/settings/store")
        local store = SettingsStore:new({ path = root .. "/suwayomi.lua" })
        local dir = root .. "/suwayomi_chapters"
        assert.is_falsy(store.io.dir_exists(dir))
        assert.is_truthy(store.io.mkdir(dir))
        assert.is_true(store.io.dir_exists(dir))
        local chapter_store = SettingsStore:new({ path = dir .. "/manga_1.lua", io = store.io })
        assert.is_true(chapter_store:saveKey("listing", { chapters = { { id = 1 } } }))
        local reloaded = SettingsStore:new({ path = dir .. "/manga_1.lua", io = store.io })
        assert.same({ chapters = { { id = 1 } } }, reloaded:readKey("listing"))
    end)
end)
