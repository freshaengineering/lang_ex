defmodule LangEx.Middleware.Filesystem do
  @moduledoc """
  Middleware that gives the agent a state-backed virtual workspace.

  Contributes six file tools (`ls`, `read_file`, `write_file`, `edit_file`,
  `glob`, `grep`) plus a `:workspace` state key holding a `path => content`
  map. The agent offloads large artifacts — evidence excerpts, long tool
  outputs, draft documents — out of chat history into named files it can
  re-read, search, and edit in later rounds. The workspace lives in graph
  state (and therefore in checkpoints), so files persist across rounds and
  survive context summarization.

  Writes are merged with `Map.merge/2`, so a write only touches its own
  path and `LangEx.Tool.Node` unions concurrent writes from parallel tool
  calls safely. A `nil` content is a tombstone: reads, listings, and
  searches skip it, and the path no longer counts against `:max_files`.

  Encourage use from the agent's system prompt (e.g. "Save large findings
  to workspace files instead of repeating them in conversation.").

  ## Options

  - `:max_file_bytes` - reject writes/edits producing a larger file
    (default 65_536)
  - `:max_files` - reject new files beyond this count (default 128)
  """

  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Tool

  @default_max_file_bytes 65_536
  @default_max_files 128
  @grep_line_cap 100

  @ls_description "List the files in your private workspace with their sizes. " <>
                    "The workspace is durable scratch space: files persist across rounds " <>
                    "and survive context summarization, so anything you saved earlier is " <>
                    "still here even after the conversation was compacted."

  @read_description "Read a file from your private workspace. For large files pass " <>
                      "offset (1-based first line) and limit (number of lines) to read a " <>
                      "window instead of the whole file. Use this to re-load material you " <>
                      "saved earlier instead of keeping it in the conversation."

  @write_description "Create or overwrite a file in your private workspace. Offload " <>
                       "large artifacts here — long tool outputs worth keeping, evidence " <>
                       "excerpts, findings notes, draft documents — instead of carrying " <>
                       "them in chat history. Files persist across rounds and survive " <>
                       "context summarization; retrieve them later with read_file, glob, " <>
                       "or grep."

  @edit_description "Edit a workspace file by replacing an exact substring with new " <>
                      "text. old_string must appear exactly once; include enough " <>
                      "surrounding text to make it unique. Use this to refine drafts and " <>
                      "notes in place without rewriting the whole file."

  @glob_description "Find workspace files by path pattern. * matches within a path " <>
                      "segment, ** matches across segments (e.g. notes/**.md or **.txt). " <>
                      "Use this to rediscover files you saved in earlier rounds."

  @grep_description "Search workspace file contents with a regular expression; returns " <>
                      "path:line_no: line for each match. Optionally scope the search " <>
                      "with path_glob. Use this to find where you recorded a fact or " <>
                      "excerpt earlier without re-reading whole files."

  @ls_schema %{"type" => "object", "properties" => %{}}

  @read_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "workspace file path"},
      "offset" => %{"type" => "integer", "description" => "1-based first line to read"},
      "limit" => %{"type" => "integer", "description" => "maximum number of lines to read"}
    },
    "required" => ["path"]
  }

  @write_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "workspace file path"},
      "content" => %{"type" => "string", "description" => "full file content"}
    },
    "required" => ["path", "content"]
  }

  @edit_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "workspace file path"},
      "old_string" => %{
        "type" => "string",
        "description" => "exact text to replace; must match exactly once"
      },
      "new_string" => %{"type" => "string", "description" => "replacement text"}
    },
    "required" => ["path", "old_string", "new_string"]
  }

  @glob_schema %{
    "type" => "object",
    "properties" => %{
      "pattern" => %{
        "type" => "string",
        "description" => "path pattern; * matches within a segment, ** across segments"
      }
    },
    "required" => ["pattern"]
  }

  @grep_schema %{
    "type" => "object",
    "properties" => %{
      "pattern" => %{"type" => "string", "description" => "regular expression to search for"},
      "path_glob" => %{
        "type" => "string",
        "description" => "optional path pattern limiting which files are searched"
      }
    },
    "required" => ["pattern"]
  }

  @doc "Builds a virtual-workspace middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts \\ []) do
    limits = %{
      max_file_bytes: Keyword.get(opts, :max_file_bytes, @default_max_file_bytes),
      max_files: Keyword.get(opts, :max_files, @default_max_files)
    }

    Middleware.new(
      name: :filesystem,
      tools: [
        ls_tool(),
        read_tool(),
        write_tool(limits),
        edit_tool(limits),
        glob_tool(),
        grep_tool()
      ],
      state_schema: [workspace: {%{}, &Map.merge/2}]
    )
  end

  defp ls_tool do
    %Tool{name: "ls", description: @ls_description, parameters: @ls_schema, function: &list/2}
  end

  defp read_tool do
    %Tool{
      name: "read_file",
      description: @read_description,
      parameters: @read_schema,
      function: &read/2
    }
  end

  defp write_tool(limits) do
    %Tool{
      name: "write_file",
      description: @write_description,
      parameters: @write_schema,
      function: fn args, context -> write(args, context, limits) end
    }
  end

  defp edit_tool(limits) do
    %Tool{
      name: "edit_file",
      description: @edit_description,
      parameters: @edit_schema,
      function: fn args, context -> edit(args, context, limits) end
    }
  end

  defp glob_tool do
    %Tool{
      name: "glob",
      description: @glob_description,
      parameters: @glob_schema,
      function: &glob/2
    }
  end

  defp grep_tool do
    %Tool{
      name: "grep",
      description: @grep_description,
      parameters: @grep_schema,
      function: &grep/2
    }
  end

  defp list(_args, %{state: state}) do
    state
    |> live_files()
    |> format_listing()
  end

  defp format_listing(files) when map_size(files) == 0, do: "workspace is empty"

  defp format_listing(files) do
    files
    |> Enum.sort()
    |> Enum.map_join("\n", fn {path, content} -> "#{path} (#{byte_size(content)} bytes)" end)
  end

  defp read(%{"path" => path} = args, %{state: state}) do
    state
    |> live_files()
    |> read_content(path, Map.get(args, "offset"), Map.get(args, "limit"))
  end

  defp read_content(files, path, offset, limit) when is_map_key(files, path) do
    files
    |> Map.fetch!(path)
    |> window(offset, limit)
  end

  defp read_content(files, path, _offset, _limit), do: not_found(files, path)

  defp window(content, nil, nil), do: content

  defp window(content, offset, limit) do
    content
    |> String.split("\n")
    |> Enum.drop(start_line(offset) - 1)
    |> take_lines(limit)
    |> Enum.join("\n")
  end

  defp start_line(nil), do: 1
  defp start_line(offset), do: offset

  defp take_lines(lines, nil), do: lines
  defp take_lines(lines, limit), do: Enum.take(lines, limit)

  defp write(%{"path" => path, "content" => content}, %{state: state, tool_call_id: id}, limits) do
    with :ok <- check_size(content, limits),
         :ok <- check_capacity(live_files(state), path, limits) do
      write_command(path, content, "Wrote #{path} (#{byte_size(content)} bytes)", id)
    end
  end

  defp edit(%{"old_string" => ""}, _context, _limits),
    do: "old_string must not be empty."

  defp edit(
         %{"path" => path, "old_string" => old, "new_string" => new},
         %{state: state, tool_call_id: id},
         limits
       ) do
    state
    |> live_files()
    |> edit_content(path, old, new, id, limits)
  end

  defp edit_content(files, path, old, new, id, limits) when is_map_key(files, path) do
    with {:ok, content} <- replace_unique(Map.fetch!(files, path), path, old, new),
         :ok <- check_size(content, limits) do
      write_command(path, content, "Edited #{path} (#{byte_size(content)} bytes)", id)
    end
  end

  defp edit_content(files, path, _old, _new, _id, _limits), do: not_found(files, path)

  defp replace_unique(content, path, old, new) do
    content
    |> matches(old)
    |> apply_replace(content, path, old, new)
  end

  defp matches(content, old), do: length(:binary.matches(content, old))

  defp apply_replace(0, _content, path, old, _new),
    do: "old_string not found in #{path}: #{inspect(old)}"

  defp apply_replace(1, content, _path, old, new), do: {:ok, String.replace(content, old, new)}

  defp apply_replace(count, _content, path, _old, _new) do
    "old_string matches #{count} times in #{path}. " <>
      "Widen the anchor with more surrounding text so it matches exactly once."
  end

  defp glob(%{"pattern" => pattern}, %{state: state}) do
    state
    |> live_files()
    |> Map.keys()
    |> Enum.filter(&glob_match?(&1, pattern))
    |> Enum.sort()
    |> format_glob(pattern)
  end

  defp format_glob([], pattern), do: "No files match #{pattern}"
  defp format_glob(paths, _pattern), do: Enum.join(paths, "\n")

  defp grep(%{"pattern" => pattern} = args, %{state: state}) do
    pattern
    |> Regex.compile()
    |> search(scoped_files(state, Map.get(args, "path_glob")))
  end

  defp scoped_files(state, nil), do: live_files(state)

  defp scoped_files(state, path_glob) do
    state
    |> live_files()
    |> Map.filter(fn {path, _content} -> glob_match?(path, path_glob) end)
  end

  defp search({:error, {reason, position}}, _files),
    do: "Invalid regex: #{reason} (at position #{position})"

  defp search({:ok, regex}, files) do
    files
    |> Enum.sort()
    |> Enum.flat_map(fn {path, content} -> file_matches(path, content, regex) end)
    |> format_matches()
  end

  defp file_matches(path, content, regex) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_no} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {line, line_no} -> "#{path}:#{line_no}: #{line}" end)
  end

  defp format_matches([]), do: "No matches."

  defp format_matches(lines) when length(lines) > @grep_line_cap do
    lines
    |> Enum.take(@grep_line_cap)
    |> Enum.join("\n")
    |> Kernel.<>("\n(truncated)")
  end

  defp format_matches(lines), do: Enum.join(lines, "\n")

  defp glob_match?(path, pattern) do
    pattern
    |> glob_regex()
    |> Regex.match?(path)
  end

  defp glob_regex(pattern) do
    pattern
    |> String.split("**")
    |> Enum.map_join(".*", &segment_regex/1)
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  defp segment_regex(segment) do
    segment
    |> String.split("*")
    |> Enum.map_join("[^/]*", &Regex.escape/1)
  end

  defp check_size(content, %{max_file_bytes: max}) when byte_size(content) > max,
    do: "File exceeds max size of #{max} bytes (got #{byte_size(content)} bytes)."

  defp check_size(_content, _limits), do: :ok

  defp check_capacity(files, path, _limits) when is_map_key(files, path), do: :ok

  defp check_capacity(files, _path, %{max_files: max}) when map_size(files) >= max,
    do: "Workspace is full (max #{max} files). Overwrite or reuse an existing file."

  defp check_capacity(_files, _path, _limits), do: :ok

  defp write_command(path, content, note, id) do
    %Command{
      update: %{
        workspace: %{path => content},
        messages: [Message.tool(note, id)]
      }
    }
  end

  defp not_found(files, path), do: "File not found: #{path}. Files: #{path_listing(files)}"

  defp path_listing(files) when map_size(files) == 0, do: "(none)"

  defp path_listing(files) do
    files
    |> Map.keys()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp live_files(state) do
    state
    |> Map.get(:workspace, %{})
    |> Map.reject(fn {_path, content} -> is_nil(content) end)
  end
end
