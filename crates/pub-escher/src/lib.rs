use pub_core::RawSpan;
use serde::{Deserialize, Serialize};

/// Raw OfficeArtFOPTE entry plus its complex payload, when present.
///
/// `op` preserves the 32-bit field exactly. Its semantic interpretation is
/// property-specific. When fComplex is set, MS-ODRAW defines `op` as the
/// byte size of the complex property data rather than the scalar value.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Fopte {
    pub opid: u16,
    pub op: u32,
    pub source: RawSpan,
    pub complex_data: Option<Vec<u8>>,
}

impl Fopte {
    pub fn property_id(&self) -> u16 {
        self.opid & 0x3fff
    }

    pub fn f_bid(&self) -> bool {
        self.opid & 0x4000 != 0
    }

    pub fn f_complex(&self) -> bool {
        self.opid & 0x8000 != 0
    }

    /// True only when the fBid bit is semantically applicable.
    ///
    /// MS-ODRAW requires fBid to be ignored for complex properties.
    pub fn op_is_blip_id(&self) -> bool {
        self.f_bid() && !self.f_complex()
    }

    pub fn complex_size(&self) -> Option<u32> {
        self.f_complex().then_some(self.op)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pub_core::StreamPath;

    fn span() -> RawSpan {
        RawSpan {
            stream: StreamPath("/Escher/EscherStm".into()),
            offset: 0,
            len: 6,
        }
    }

    #[test]
    fn opid_flags_are_kept_separate_from_property_id() {
        let entry = Fopte {
            opid: 0xc104,
            op: 12,
            source: span(),
            complex_data: Some(vec![0; 12]),
        };

        assert_eq!(entry.property_id(), 0x0104);
        assert!(entry.f_bid());
        assert!(entry.f_complex());
        assert!(!entry.op_is_blip_id());
        assert_eq!(entry.complex_size(), Some(12));
    }

    #[test]
    fn non_complex_fbid_can_identify_blip_reference() {
        let entry = Fopte {
            opid: 0x4104,
            op: 3,
            source: span(),
            complex_data: None,
        };

        assert_eq!(entry.property_id(), 0x0104);
        assert!(entry.f_bid());
        assert!(!entry.f_complex());
        assert!(entry.op_is_blip_id());
        assert_eq!(entry.complex_size(), None);
    }
}
