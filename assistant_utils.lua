local util = require("util")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local T = require("ffi/util").template
local koutil = require("util")
local NetworkMgr = require("ui/network/manager")
local _ = require("assistant_gettext")

local function normalizePageText(page_text)
    if type(page_text) ~= "table" then
        return page_text or ""
    end

    local texts = {}
    for _, block in ipairs(page_text) do
        if type(block) == "table" then
            for i = 1, #block do
                local span = block[i]
                if type(span) == "table" and span.word then
                    table.insert(texts, span.word)
                end
            end
        end
    end
    return table.concat(texts, " ")
end

local function getCurrentPageNumber(ui)
    local document = ui.document
    local current_page

    if document.info.has_pages then
        current_page = ui.view and ui.view.state and ui.view.state.page
    end

    if not current_page then
        local ok, xp = pcall(function() return document:getXPointer() end)
        if ok and xp then
            local page_ok, page = pcall(function() return document:getPageFromXPointer(xp) end)
            if page_ok then
                current_page = page
            end
        end
    end

    return math.max(1, tonumber(current_page) or 1)
end

local function extractRecentPagesText(CONFIGURATION, ui)
    local document = ui.document
    local configured_lookback = koutil.tableGetValue(CONFIGURATION, "features", "page_lookback_count")
    local page_lookback_count = tonumber(configured_lookback) or 10
    page_lookback_count = math.max(1, math.floor(page_lookback_count))

    local current_page = getCurrentPageNumber(ui)
    local count_ok, total_pages = pcall(function() return document:getPageCount() end)
    if count_ok and tonumber(total_pages) and tonumber(total_pages) > 0 then
        current_page = math.min(current_page, tonumber(total_pages))
    end
    current_page = math.max(1, current_page)

    local start_page = math.max(1, current_page - page_lookback_count)
    local recent_text = ""

    if document.info.has_pages then
        local pages = {}
        for page = start_page, current_page do
            local page_ok, page_text = pcall(function() return document:getPageText(page) end)
            table.insert(pages, page_ok and normalizePageText(page_text) or "")
        end
        recent_text = table.concat(pages, "\n")
    else
        local end_ok, end_xp = pcall(function() return document:getXPointer() end)
        local start_ok, start_xp = pcall(function() return document:getPageXPointer(start_page) end)
        if end_ok and start_ok and end_xp and start_xp then
            local text_ok, text = pcall(function() return document:getTextFromXPointers(start_xp, end_xp) end)
            if text_ok and text then
                recent_text = text
            end
        end
    end

    local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
    if #recent_text > max_text_length_for_analysis then
        recent_text = recent_text:sub(-max_text_length_for_analysis)
    end

    return recent_text, start_page, current_page
end

local function extractBookTextForAnalysis(CONFIGURATION, ui)
    local book_text = nil
      if not ui.document.info.has_pages then
          -- Only extract text for EPUB documents
          local current_xp = ui.document:getXPointer()
          ui.document:gotoPos(0)
          local start_xp = ui.document:getXPointer()
          ui.document:gotoXPointer(current_xp)
          book_text = ui.document:getTextFromXPointers(start_xp, current_xp) or ""
          local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
          if #book_text > max_text_length_for_analysis then
              book_text = book_text:sub(-max_text_length_for_analysis)
          end
      else
        -- Extract text from the last n pages up to current reading position for page-based documents
        local current_page = ui.view.state.page
        local total_pages = ui.document:getPageCount()
        local max_page_size_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_page_size_for_analysis") or 250
        local start_page = math.max(1, current_page - max_page_size_for_analysis)
        book_text = ""
        for page = start_page, current_page do
            local page_text = normalizePageText(ui.document:getPageText(page))
            book_text = book_text .. page_text .. "\n"
        end
        local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
        if #book_text > max_text_length_for_analysis then
            book_text = book_text:sub(-max_text_length_for_analysis)
        end
    end
    return book_text
end

local function extractHighlightsNotesAndNotebook(CONFIGURATION, ui, include_notebook)
    local highlights_and_notes = ""
    if ui.annotation and ui.annotation.annotations then
        for _, annotation in ipairs(ui.annotation.annotations) do
            if annotation.text and annotation.text ~= "" then
                highlights_and_notes = highlights_and_notes .. "Highlight: " .. annotation.text .. "\n"
            end
            if annotation.note and annotation.note ~= "" then
                highlights_and_notes = highlights_and_notes .. "Note: " .. annotation.note .. "\n"
            end
            if annotation.chapter then
                highlights_and_notes = highlights_and_notes .. "Chapter: " .. annotation.chapter .. "\n"
            end
            if annotation.pageno then
                highlights_and_notes = highlights_and_notes .. "Page: " .. annotation.pageno .. "\n"
            end
            highlights_and_notes = highlights_and_notes .. "\n"
        end
    end
    
    local notebook_content = ""
    if include_notebook then
      pcall(function()
          local notebookfile = ui.bookinfo:getNotebookFile(ui.doc_settings)
          if notebookfile then
              local json = require("json")
              local file = io.open(notebookfile, "r")
              if file then
                  local content = file:read("*all")
                  file:close()
                  local success, data = pcall(json.decode, content)
                  if success and data then
                      notebook_content = "Notebook Data:\n" .. json.encode(data)
                  else
                      notebook_content = "Notebook Content (raw):\n" .. content
                  end
              end
          end
      end)
    end
    
    local combined = highlights_and_notes
    if notebook_content ~= "" then
        if combined ~= "" then
            combined = combined .. "\n--- Notebook Content ---\n" .. notebook_content
        else
            combined = notebook_content
        end
    end
    
    local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
    if #combined > max_text_length_for_analysis then
        combined = combined:sub(-max_text_length_for_analysis)
    end
    
    return combined
end

local function getPageInfo(ui)
  local page_number = nil
  local percentage = 0
  local total_pages = nil
  local chapter_title = nil
  if ui.highlight.selected_text and ui.highlight.selected_text.pos0 then
    if ui.paging then
      page_number = ui.highlight.selected_text.pos0.page
    else
      -- For rolling mode, we could get page number using document:getPageFromXPointer
      page_number = ui.document:getPageFromXPointer(ui.highlight.selected_text.pos0)
    end
    
    total_pages = ui.document.info.number_of_pages
    if page_number and total_pages and total_pages ~= 0 then
      percentage = math.floor((page_number / total_pages) * 100 + 0.5)
    end
    
    if ui.toc and page_number then
      chapter_title = ui.toc:getTocTitleByPage(page_number)
    end
  end

  local page_lbl = _("Page")
  local page_info = ""
  if page_number and total_pages then
    page_info = string.format(" (%s %s - %s%%)", page_lbl, page_number, percentage)
  elseif page_number then
    page_info = string.format(" (%s %s)", page_lbl, page_number)
  end

  if chapter_title then
    page_info = page_info .. " - " .. chapter_title
  end

  return page_info
end

local function saveToNotebookFile(assistant, log_entry)
  local success, err = pcall(function()
    local notebookfile = assistant.ui.bookinfo:getNotebookFile(assistant.ui.doc_settings)
    local default_folder = util.tableGetValue(assistant.CONFIGURATION, "features", "default_folder_for_logs")
    if default_folder and default_folder ~= "" then
      if not notebookfile:find("^" .. default_folder:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")) then
        if not util.pathExists(default_folder) then
          UIManager:show(InfoMessage:new{
              icon = "notice-warning",
              text = T(_("Cannot access default folder for logs: %1\nUsing original location."), default_folder),
              timeout = 5,
            })
        else
          local original_filename = notebookfile:match("([^/\\]+)$")
          if original_filename then
            original_filename = original_filename:gsub("%.[^.]*$", ".md")
          else
            local doc_path = assistant.ui.document.file
            if doc_path then
              local doc_filename = doc_path:match("([^/\\]+)$")
              if doc_filename then
                original_filename = doc_filename..".md"
              else
                original_filename = "notebook.md"
              end
            else
              original_filename = "notebook.md"
            end
          end
          local new_notebookfile = default_folder .. "/" .. original_filename

          assistant.ui.doc_settings:saveSetting("notebook_file", new_notebookfile)

          notebookfile = new_notebookfile
        end
      end
    end

    if notebookfile and not notebookfile:find("%.md$") then
      notebookfile = notebookfile:gsub("%.[^.]*$", ".md")
      if not notebookfile:find("%.md$") then
        notebookfile = notebookfile .. ".md"
      end
      assistant.ui.doc_settings:saveSetting("notebook_file", notebookfile)
    end

    if notebookfile then
      local file = io.open(notebookfile, "a")
      if file then
        file:write(log_entry)
        file:close()
      else
        logger.warn("Assistant: Could not open notebook file:", notebookfile)
      end
    end
  end)

  if not success then
    logger.warn("Assistant: Error during notebook save:", err)
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Notebook save failed. Continuing..."),
      timeout = 3,
    })
  end
end

-- Timer-based wifi disable shared across all prompts

local wifi_disable_timer = nil

-- Resolve the effective delay: the runtime UI setting overrides configuration.lua.
-- Returns nil when auto-disable is disabled, otherwise a number of seconds (0 = immediately).
local function getWifiDisableDelay(CONFIGURATION, settings)
    local delay_sec
    if settings and settings:has("wifi_disable_delay") then
        delay_sec = settings:readSetting("wifi_disable_delay")
    else
        delay_sec = koutil.tableGetValue(CONFIGURATION, "features", "wifi_disable_delay")
    end

    -- `false` is used by the settings UI to mean "never disable Wi-Fi".
    if delay_sec == nil or delay_sec == false then return nil end
    return tonumber(delay_sec)
end

local function cancelWifiDisable()
    if wifi_disable_timer then
        UIManager:unschedule(wifi_disable_timer)
        wifi_disable_timer = nil
    end
end

local function applyWifiDisableDelay(CONFIGURATION, settings)
    local delay_sec = getWifiDisableDelay(CONFIGURATION, settings)
    cancelWifiDisable()
    if delay_sec == nil then return end
    if not NetworkMgr:isWifiOn() then return end

    if delay_sec > 0 then
        wifi_disable_timer = function()
            wifi_disable_timer = nil
            NetworkMgr:disableWifi(nil, true)
        end
        UIManager:scheduleIn(delay_sec, wifi_disable_timer)
    else
        NetworkMgr:disableWifi(nil, true)
    end
end

local function scheduleWifiDisable(CONFIGURATION, settings)
    applyWifiDisableDelay(CONFIGURATION, settings)
end

-- Re-apply the delay when a timer is already pending, so UI changes take effect immediately.
local function refreshWifiDisableTimer(CONFIGURATION, settings)
    if not wifi_disable_timer then return end
    applyWifiDisableDelay(CONFIGURATION, settings)
end

return {
    extractBookTextForAnalysis = extractBookTextForAnalysis,
    extractRecentPagesText = extractRecentPagesText,
    extractHighlightsNotesAndNotebook = extractHighlightsNotesAndNotebook,
    getPageInfo = getPageInfo,
    saveToNotebookFile = saveToNotebookFile,
    getWifiDisableDelay = getWifiDisableDelay,
    scheduleWifiDisable = scheduleWifiDisable,
    refreshWifiDisableTimer = refreshWifiDisableTimer
}
