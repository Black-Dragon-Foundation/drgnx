# Writing documents with agents

A spec or a plan is often written by an agent while you read along. You answer it the way you would a colleague's
draft: with comments on the paragraphs you want changed.

## Paragraph comments

A comment sits on one paragraph of a spec, plan, decision record or task. It starts a thread: the agent answers in
it, and you can reply.

- **Who gets it.** Your comment goes to the agent that is writing the document: the agent whose edit to the file is
  the newest. When no agent has edited it, the comment goes to an agent working on one of the plan's tasks.
- **It never interrupts.** An idle agent gets the comment at once. A busy one reads it at its next turn, ahead of
  anything else waiting for it. A turn it is in the middle of is never cancelled.
- **No agent writing it.** When no agent is writing the document, the thread waits. The document's Detail in the Work
  space says "1 comment waiting: no agent is writing it". The comment goes out by itself when an agent starts on the
  document.
- **The agent answers in the thread.** It sees where the comment sits and what you said, and answers with the
  `comment_reply` tool. Only the agent your comment went to can answer it.
- **Resolve** a thread once it is settled. It stays in the document's history.

## When the paragraph changes

The thread follows its paragraph, even when the agent rewrites the paragraph in answer to you.

- **Unchanged:** the thread stays where it is.
- **Rewritten:** the thread moves to the paragraph that replaced it, the one most like it, and says it moved.
- **Deleted:** the thread stays, marked "paragraph removed", with the paragraph's old text quoted. A thread is never
  dropped. If the paragraph comes back, the thread is back on it.
