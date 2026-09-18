use serde::{Deserialize,Serialize};
#[derive(Debug,Default,Clone,Serialize,Deserialize)]
pub struct EditorDocument{pub pages:Vec<Page>}
#[derive(Debug,Clone,Serialize,Deserialize)]
pub struct Page{pub native_id:u32,pub shapes:Vec<Shape>}
#[derive(Debug,Clone,Serialize,Deserialize)]
pub struct Shape{pub native_id:u32,pub text:Option<String>}
