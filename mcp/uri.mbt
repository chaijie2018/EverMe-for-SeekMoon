// Resource URIs. `mem://profile` is static; `mem://search?q=…&topK=…` is a
// template a host expands with model-authored text, so the query arrives
// percent-encoded and has to be decoded before it reaches the backend. Both the
// `q`/`query` and `topK`/`top_k` spellings are accepted, as upstream does — a
// model guessing the name should still get a search.

///|
/// The hex value of `ch`, or -1 when it is not a hex digit.
fn hex_value(ch : Char) -> Int32 {
  match ch {
    '0'..<='9' => ch.to_int() - '0'.to_int()
    'a'..<='f' => ch.to_int() - 'a'.to_int() + 10
    'A'..<='F' => ch.to_int() - 'A'.to_int() + 10
    _ => -1
  }
}

///|
/// Percent-decode `text` (`%XX` and `+`), falling back to the input when the
/// bytes are not valid UTF-8.
pub fn percent_decode(text : String) -> String {
  let bytes : Array[Byte] = []
  let length = text.length()
  let mut index = 0
  while index < length {
    let ch = text.get_char(index).unwrap_or(' ')
    if ch == '%' && index + 2 < length {
      let hi = hex_value(text.get_char(index + 1).unwrap_or(' '))
      let lo = hex_value(text.get_char(index + 2).unwrap_or(' '))
      if hi >= 0 && lo >= 0 {
        bytes.push((hi * 16 + lo).to_byte())
        index = index + 3
        continue
      }
    }
    if ch == '+' {
      bytes.push((32 : Int32).to_byte())
      index = index + 1
      continue
    }
    for byte in @utf8.encode(ch.to_string()) {
      bytes.push(byte)
    }
    index = index + 1
  }
  let buffer = Bytes::from_array(bytes[:])
  @utf8.decode(buffer[:]) catch {
    _ => text
  }
}

///|
/// What a `mem://search` URI asked for.
pub(all) struct SearchUri {
  query : String
  top_k : Int32
}

///|
/// Parse `mem://search…`; `None` when the URI is a different resource.
pub fn parse_search_uri(uri : String) -> SearchUri? {
  if uri != "mem://search" && !uri.has_prefix("mem://search?") {
    return None
  }
  let parameters = match uri.split_once("?") {
    Some((_, rest)) => rest.to_owned()
    None => ""
  }
  let mut query = ""
  let mut top_k = @api.TopKDefault
  for pair in parameters.split("&") {
    match pair.split_once("=") {
      Some((name, value)) => {
        let name = name.to_owned()
        let value = percent_decode(value.to_owned())
        if name == "q" || name == "query" {
          query = value
        } else if name == "topK" || name == "top_k" {
          let parsed : Int32 = @string.from_str(value.trim()) catch { _ => 0 }
          top_k = @api.normalize_top_k(parsed)
        }
      }
      None => ()
    }
  }
  Some({ query: @api.clamp_query(query), top_k, })
}
