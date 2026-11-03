// ==============================================================================
// Mimra Core — Hex Color Parsing & Swatch Support (F-037, T-TYPE-06)
// ==============================================================================

use serde::{Deserialize, Serialize};

/// Represents a parsed RGBA color from a hex string.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct HexColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl HexColor {
    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    /// Parses a string into a `HexColor` if it represents a valid hex color code.
    /// Supports `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, as well as `0xRRGGBB` and `0xRRGGBBAA`.
    /// Strips leading and trailing whitespace.
    pub fn parse(input: &str) -> Option<Self> {
        let trimmed = input.trim();
        let hex_str = if let Some(stripped) = trimmed.strip_prefix('#') {
            stripped
        } else {
            trimmed
                .strip_prefix("0x")
                .or_else(|| trimmed.strip_prefix("0X"))?
        };

        if !hex_str.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }

        match hex_str.len() {
            // #RGB (4-bit per channel expanded to 8-bit)
            3 => {
                let r = u8::from_str_radix(&hex_str[0..1], 16).ok()?;
                let g = u8::from_str_radix(&hex_str[1..2], 16).ok()?;
                let b = u8::from_str_radix(&hex_str[2..3], 16).ok()?;
                Some(Self {
                    r: (r << 4) | r,
                    g: (g << 4) | g,
                    b: (b << 4) | b,
                    a: 255,
                })
            }
            // #RGBA
            4 => {
                let r = u8::from_str_radix(&hex_str[0..1], 16).ok()?;
                let g = u8::from_str_radix(&hex_str[1..2], 16).ok()?;
                let b = u8::from_str_radix(&hex_str[2..3], 16).ok()?;
                let a = u8::from_str_radix(&hex_str[3..4], 16).ok()?;
                Some(Self {
                    r: (r << 4) | r,
                    g: (g << 4) | g,
                    b: (b << 4) | b,
                    a: (a << 4) | a,
                })
            }
            // #RRGGBB
            6 => {
                let r = u8::from_str_radix(&hex_str[0..2], 16).ok()?;
                let g = u8::from_str_radix(&hex_str[2..4], 16).ok()?;
                let b = u8::from_str_radix(&hex_str[4..6], 16).ok()?;
                Some(Self { r, g, b, a: 255 })
            }
            // #RRGGBBAA
            8 => {
                let r = u8::from_str_radix(&hex_str[0..2], 16).ok()?;
                let g = u8::from_str_radix(&hex_str[2..4], 16).ok()?;
                let b = u8::from_str_radix(&hex_str[4..6], 16).ok()?;
                let a = u8::from_str_radix(&hex_str[6..8], 16).ok()?;
                Some(Self { r, g, b, a })
            }
            _ => None,
        }
    }

    /// Formats as standard uppercase `#RRGGBB` string.
    pub fn to_hex_string(&self) -> String {
        format!("#{:02X}{:02X}{:02X}", self.r, self.g, self.b)
    }

    /// Formats as uppercase `#RRGGBBAA` string with alpha.
    pub fn to_rgba_hex_string(&self) -> String {
        format!("#{:02X}{:02X}{:02X}{:02X}", self.r, self.g, self.b, self.a)
    }

    /// Returns normalized RGBA components in range 0.0..=1.0.
    pub fn to_rgba_f32(&self) -> (f32, f32, f32, f32) {
        (
            self.r as f32 / 255.0,
            self.g as f32 / 255.0,
            self.b as f32 / 255.0,
            self.a as f32 / 255.0,
        )
    }

    /// Calculates ITU-R BT.601 perceptual luminance to determine whether the color is dark.
    /// Useful for deciding swatch outline contrast.
    pub fn is_perceptually_dark(&self) -> bool {
        let luminance = 0.299 * (self.r as f64) + 0.587 * (self.g as f64) + 0.114 * (self.b as f64);
        luminance < 128.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_valid_rgb() {
        let color = HexColor::parse("#f0a").expect("Should parse #f0a");
        assert_eq!(color.r, 0xff);
        assert_eq!(color.g, 0x00);
        assert_eq!(color.b, 0xaa);
        assert_eq!(color.a, 255);
        assert_eq!(color.to_hex_string(), "#FF00AA");
    }

    #[test]
    fn test_parse_valid_rgba() {
        let color = HexColor::parse("#1238").expect("Should parse #1238");
        assert_eq!(color.r, 0x11);
        assert_eq!(color.g, 0x22);
        assert_eq!(color.b, 0x33);
        assert_eq!(color.a, 0x88);
    }

    #[test]
    fn test_parse_valid_rrggbb() {
        let color = HexColor::parse("#336699").expect("Should parse #336699");
        assert_eq!(color.r, 0x33);
        assert_eq!(color.g, 0x66);
        assert_eq!(color.b, 0x99);
        assert_eq!(color.a, 255);
        assert_eq!(color.to_hex_string(), "#336699");
    }

    #[test]
    fn test_parse_valid_rrggbbaa() {
        let color = HexColor::parse("#FF573380").expect("Should parse #FF573380");
        assert_eq!(color.r, 0xff);
        assert_eq!(color.g, 0x57);
        assert_eq!(color.b, 0x33);
        assert_eq!(color.a, 0x80);
        assert_eq!(color.to_rgba_hex_string(), "#FF573380");
    }

    #[test]
    fn test_parse_0x_prefix() {
        let color = HexColor::parse("0xFF00AA").expect("Should parse 0xFF00AA");
        assert_eq!(color.r, 0xff);
        assert_eq!(color.g, 0x00);
        assert_eq!(color.b, 0xaa);
        assert_eq!(color.a, 255);
    }

    #[test]
    fn test_parse_with_whitespace() {
        let color = HexColor::parse("  #00FF00  \n").expect("Should trim whitespace");
        assert_eq!(color.r, 0x00);
        assert_eq!(color.g, 0xff);
        assert_eq!(color.b, 0x00);
    }

    #[test]
    fn test_parse_invalid_hex() {
        assert!(HexColor::parse("").is_none());
        assert!(HexColor::parse("#").is_none());
        assert!(HexColor::parse("#12").is_none());
        assert!(HexColor::parse("#12345").is_none());
        assert!(HexColor::parse("#1234567").is_none());
        assert!(HexColor::parse("#123456789").is_none());
        assert!(HexColor::parse("#GG0011").is_none());
        assert!(HexColor::parse("random text").is_none());
    }

    #[test]
    fn test_luminance_and_dark() {
        let black = HexColor::parse("#000000").unwrap();
        assert!(black.is_perceptually_dark());

        let white = HexColor::parse("#FFFFFF").unwrap();
        assert!(!white.is_perceptually_dark());
    }
}
