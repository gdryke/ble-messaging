pub mod message;
pub mod chunk;
pub mod handshake;

/// BLE Service UUID base: D7A0xxxx-E28C-4B8E-8C3F-4A77C4D2F5B1
pub const SERVICE_UUID: &str = "D7A00001-E28C-4B8E-8C3F-4A77C4D2F5B1";
pub const CHAR_INBOX_WRITE: &str = "D7A00002-E28C-4B8E-8C3F-4A77C4D2F5B1";
pub const CHAR_OUTBOX_NOTIFY: &str = "D7A00003-E28C-4B8E-8C3F-4A77C4D2F5B1";
pub const CHAR_HANDSHAKE: &str = "D7A00004-E28C-4B8E-8C3F-4A77C4D2F5B1";
pub const CHAR_ACK: &str = "D7A00005-E28C-4B8E-8C3F-4A77C4D2F5B1";

/// Protocol version
pub const PROTOCOL_VERSION: u8 = 0x01;

/// Maximum plaintext body size (bytes)
pub const MAX_BODY_SIZE: usize = 4096;
