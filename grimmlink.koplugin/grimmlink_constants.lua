local M = {}

M.DEFAULTS = {
    enabled = true,
    settings_tab_enabled = true,
    server_url = "",
    remote_url = "",
    local_url_nickname = "",
    remote_url_nickname = "",
    home_ssid = "",
    username = "",
    password = "",
    first_run_setup_completed = false,
    first_run_setup_dismissed = false,
    device_name = "KOReader",
    device_id = nil,
    auto_pull_on_open = true,
    auto_push_on_close = true,
    offline_queue_enabled = true,
    e_reader_friendly_mode = false,
    auto_sync_cooldown_seconds = 300,
    ask_wifi_before_sync = true,
    sync_on_network_connected = false,
    network_sync_cooldown_seconds = 300,
    pending_shelf_removal_retry_cooldown_seconds = 30,
    debug_logging = false,
    log_to_file = false,
    threshold_percent = 1.0,
    threshold_minutes = 5,
    threshold_pages = 5,
    session_min_seconds = 30,
    shelf_sync_enabled = false,
    shelf_id = nil,
    shelf_name = "",
    shelf_type = "regular",
    download_dir = "",
    sync_regular_shelf_enabled = false,
    selected_regular_shelf_id = nil,
    selected_regular_shelf_name = "",
    sync_magic_shelf_enabled = false,
    selected_magic_shelf_id = nil,
    selected_magic_shelf_name = "",
    use_separate_magic_download_dir = false,
    magic_download_dir = "",
    shelf_fast_sync_enabled = true,
    shelf_fast_sync_cache_seconds = 15,
    shelf_plan_batch_size = 60,
    auto_sync_shelf_on_resume = false,
    two_way_shelf_delete_sync = false,
    shelf_use_original_filename = true,
    delete_sdr_on_book_delete = false,
    refresh_bookinfo_after_shelf_sync = true,
    refresh_bookinfo_batch_size = 20,
    auto_update_enabled = false,
    check_update_on_startup = false,
    update_channel = "stable",
    update_repo = "0xstillb/grimmlink",
    allow_prerelease_updates = false,
    metadata_sync_enabled = false,
    rating_sync_enabled = true,
    annotations_sync_enabled = true,
    bookmarks_sync_enabled = true,
    metadata_retry_max = 5,
    send_reflowable_percentage = true,
}

M.E_READER_FRIENDLY_PRESET = {
    offline_queue_enabled = true,
    ask_wifi_before_sync = true,
    sync_on_network_connected = true,
    network_sync_cooldown_seconds = 300,
    auto_sync_shelf_on_resume = false,
    auto_pull_on_open = true,
    auto_push_on_close = true,
}

M.DISK_SPACE_SAFETY_MARGIN_BYTES = 20 * 1024 * 1024
M.READ_STATUS_CAPABILITY_CACHE_SECONDS = 300
M.DIR_PICKER_MAX_SCAN_ENTRIES = 500
M.DIR_PICKER_MAX_SHOW_DIRS = 60
M.READING_COMPLETION_PROMPT_THRESHOLD_PERCENT = 99
M.READING_COMPLETION_PROMPT_RESET_PERCENT = 95
M.READING_COMPLETION_PROMPT_STATE_KEY = "grimmlink_reading_completion_prompt"
M.READING_COMPLETION_RATING_STATE_KEY = "grimmlink_rating_state"
M.READING_COMPLETION_END_DIALOG_INITIAL_DELAY_SECONDS = 0.05
M.READING_COMPLETION_END_DIALOG_POLL_SECONDS = 0.25
M.READING_COMPLETION_END_DIALOG_MAX_ATTEMPTS = 80
M.SETTINGS_BACKUP_SCHEMA_VERSION = 1
M.SETTINGS_BACKUP_DIRECTORY_NAME = "Grimmlink-setting-backup"
M.SETTINGS_BACKUP_FILE_NAME = "grimmlink-settings-backup.json"
M.LOCAL_DIAGNOSTICS_SCHEMA_VERSION = 1
M.LOCAL_DIAGNOSTICS_DIRECTORY_NAME = "Grimmlink-diagnostics"
M.LOCAL_DIAGNOSTICS_FILE_NAME = "grimmlink-diagnostics-bundle.json"
M.HISTORICAL_IMPORT_DEFAULT_FILE_NAME = "statistics.sqlite3"
M.HISTORICAL_IMPORT_GAP_SECONDS = 300

M.SETTINGS_BACKUP_KEYS = {
    "enabled",
    "settings_tab_enabled",
    "server_url",
    "remote_url",
    "local_url_nickname",
    "remote_url_nickname",
    "home_ssid",
    "username",
    "password",
    "first_run_setup_completed",
    "device_name",
    "device_id",
    "auto_pull_on_open",
    "auto_push_on_close",
    "offline_queue_enabled",
    "e_reader_friendly_mode",
    "ask_wifi_before_sync",
    "sync_on_network_connected",
    "network_sync_cooldown_seconds",
    "pending_shelf_removal_retry_cooldown_seconds",
    "debug_logging",
    "log_to_file",
    "threshold_percent",
    "threshold_minutes",
    "threshold_pages",
    "session_min_seconds",
    "shelf_sync_enabled",
    "shelf_id",
    "shelf_name",
    "shelf_type",
    "download_dir",
    "sync_regular_shelf_enabled",
    "selected_regular_shelf_id",
    "selected_regular_shelf_name",
    "sync_magic_shelf_enabled",
    "selected_magic_shelf_id",
    "selected_magic_shelf_name",
    "use_separate_magic_download_dir",
    "magic_download_dir",
    "shelf_fast_sync_enabled",
    "shelf_fast_sync_cache_seconds",
    "shelf_plan_batch_size",
    "auto_sync_shelf_on_resume",
    "two_way_shelf_delete_sync",
    "shelf_use_original_filename",
    "delete_sdr_on_book_delete",
    "refresh_bookinfo_after_shelf_sync",
    "refresh_bookinfo_batch_size",
    "auto_update_enabled",
    "check_update_on_startup",
    "update_channel",
    "update_repo",
    "allow_prerelease_updates",
    "metadata_sync_enabled",
    "rating_sync_enabled",
    "annotations_sync_enabled",
    "bookmarks_sync_enabled",
    "metadata_retry_max",
}

M.FIXED_PAGE_FORMATS = {
    PDF = true,
    CBX = true,
    CBZ = true,
    CBR = true,
    CB7 = true,
    DJVU = true,
    DJV = true,
}

M.REFLOWABLE_FORMATS = {
    EPUB = true,
    MOBI = true,
    AZW = true,
    AZW3 = true,
    FB2 = true,
    HTML = true,
    HTM = true,
    TXT = true,
    DOCX = true,
}

return M
