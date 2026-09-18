use pub_core::RawSpan;
use serde::{Deserialize,Serialize};
#[derive(Debug,Clone,Serialize,Deserialize)]
pub struct Fopte{pub opid:u16,pub value:u32,pub source:RawSpan,pub complex_data:Option<Vec<u8>>}
impl Fopte{
    pub fn property_id(&self)->u16{self.opid&0x3fff}
    pub fn is_complex(&self)->bool{self.opid&0x8000!=0}
    pub fn is_blip_id(&self)->bool{self.opid&0x4000!=0}
}
