// Executing a decided action: the thin, IO-bound half of the server. Every
// backend failure becomes a string so the caller can choose the protocol shape —
// a tool error for a tool call, a JSON-RPC error for a resource read.

///|
/// A one-line description of a backend failure that is safe to show a model:
/// the classification, the backend's own words, and the request id support needs.
fn describe(failure : @api.Failure) -> String {
  let request = if failure.request_id.is_empty() {
    ""
  } else {
    " (requestId=\{failure.request_id})"
  }
  "\{failure.kind}: \{failure.message}\{request}"
}

///|
/// The status object a save returns, as JSON text. `profileUpdated` is the only
/// signal that a stated fact really reached the profile, so it is reported for
/// both paths — the personal endpoint reports `extracted`, the trajectory one
/// reports `personalExtracted` for its derived transcript.
pub fn save_report(
  result : Json,
  request_id : String,
  personal : Bool,
) -> String {
  let extracted = if personal {
    @api.bool_field(result, "extracted")
  } else {
    @api.bool_field(result, "personalExtracted")
  }
  let report : Json = {
    "saved": true,
    "status": Json(@api.string_field(result, "status")),
    "messageCount": Json(@api.int_field(result, "messageCount")),
    "flushed": Json(@api.bool_field(result, "flushed")),
    "extracted": Json(extracted),
    "profileUpdated": Json(extracted),
    "requestId": Json(request_id),
  }
  report.stringify()
}

///|
/// `mem_search`, shared by the tool and the resource: both answer with the same
/// markdown, and both need the same "nothing matched" note.
async fn search_markdown(
  client : @api.Client,
  query : String,
  top_k : Int32,
) -> Result[String, String] {
  let bundle = client.search(query~, top_k~) catch {
    @api.ApiError(failure) => return Err(describe(failure))
  }
  let markdown = @render.search_markdown(bundle)
  if markdown.is_empty() {
    Ok(@render.empty_search_note(query))
  } else {
    Ok(markdown)
  }
}

///|
/// Run one action against the backend.
pub async fn execute(
  action : Action,
  client : @api.Client,
) -> Result[Json, String] {
  match action {
    Context(force_refresh~) => {
      let bundle = client.context(force_refresh~) catch {
        @api.ApiError(failure) => return Err(describe(failure))
      }
      let markdown = @render.profile_markdown(bundle)
      let text = if markdown.is_empty() {
        "_(no profile available — this EverMe account has no extracted memories yet)_"
      } else {
        markdown
      }
      Ok(tool_text(text))
    }
    Search(query~, top_k~) =>
      match search_markdown(client, query, top_k) {
        Ok(markdown) => Ok(tool_text(markdown))
        Err(message) => Err(message)
      }
    SaveFact(messages~, session_key~, flush~) => {
      let (result, request_id) = client.save_personal(
        conversation_id=session_key,
        messages~,
        flush~,
      ) catch {
        @api.ApiError(failure) => return Err(describe(failure))
      }
      Ok(tool_text(save_report(result, request_id, true)))
    }
    SaveTurn(messages~, session_key~, flush~) => {
      let (result, request_id) = client.save_agent_memory(
        conversation_id=session_key,
        messages~,
        flush~,
      ) catch {
        @api.ApiError(failure) => return Err(describe(failure))
      }
      Ok(tool_text(save_report(result, request_id, false)))
    }
    Profile => {
      let bundle = client.context(force_refresh=false) catch {
        @api.ApiError(failure) => return Err(describe(failure))
      }
      let markdown = @render.profile_markdown(bundle)
      let text = if markdown.is_empty() {
        "_(no profile available)_"
      } else {
        markdown
      }
      Ok(resource_text("mem://profile", text))
    }
    SearchResource(query~, top_k~) =>
      match search_markdown(client, query, top_k) {
        Ok(markdown) =>
          Ok(resource_text("mem://search?q=\{query}&topK=\{top_k}", markdown))
        Err(message) => Err(message)
      }
  }
}
