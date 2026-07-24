defmodule LangEx.Middleware.FilesystemTest do
  use ExUnit.Case, async: true

  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Middleware.Filesystem
  alias LangEx.Tool

  describe "new/1" do
    test "contributes the six workspace tools" do
      assert ["edit_file", "glob", "grep", "ls", "read_file", "write_file"] =
               Filesystem.new().tools |> Enum.map(& &1.name) |> Enum.sort()
    end

    test "contributes the :workspace state key with a merging reducer" do
      assert [workspace: {%{}, reducer}] = Filesystem.new().state_schema

      assert %{"a.txt" => "one", "b.txt" => "two"} =
               reducer.(%{"a.txt" => "one"}, %{"b.txt" => "two"})
    end

    test "reducer unions two sequential write commands and keeps tombstones" do
      [workspace: {default, reducer}] = Filesystem.new().state_schema

      %Tool{function: write} =
        Enum.find(Filesystem.new().tools, &(&1.name == "write_file"))

      %Command{update: %{workspace: first}} =
        write.(%{"path" => "a.txt", "content" => "one"}, %{
          state: %{workspace: default},
          tool_call_id: "t1"
        })

      %Command{update: %{workspace: second}} =
        write.(%{"path" => "b.txt", "content" => "two"}, %{
          state: %{workspace: reducer.(default, first)},
          tool_call_id: "t2"
        })

      merged = default |> reducer.(first) |> reducer.(second)

      assert %{"a.txt" => "one", "b.txt" => "two"} = merged
      assert %{"a.txt" => nil, "b.txt" => "two"} = reducer.(merged, %{"a.txt" => nil})
    end
  end

  describe "ls" do
    test "reports an empty workspace" do
      %Tool{function: ls} = Enum.find(Filesystem.new().tools, &(&1.name == "ls"))

      assert "workspace is empty" = ls.(%{}, %{state: %{workspace: %{}}, tool_call_id: "t1"})
    end

    test "lists paths sorted with byte sizes, skipping tombstones" do
      %Tool{function: ls} = Enum.find(Filesystem.new().tools, &(&1.name == "ls"))

      workspace = %{"b.txt" => "hello", "a.txt" => "hi", "gone.txt" => nil}

      assert "a.txt (2 bytes)\nb.txt (5 bytes)" =
               ls.(%{}, %{state: %{workspace: workspace}, tool_call_id: "t1"})
    end
  end

  describe "read_file" do
    test "returns the full content" do
      %Tool{function: read} = Enum.find(Filesystem.new().tools, &(&1.name == "read_file"))

      assert "line one\nline two" =
               read.(%{"path" => "notes.md"}, %{
                 state: %{workspace: %{"notes.md" => "line one\nline two"}},
                 tool_call_id: "t1"
               })
    end

    test "applies the offset/limit line window" do
      %Tool{function: read} = Enum.find(Filesystem.new().tools, &(&1.name == "read_file"))

      state = %{workspace: %{"notes.md" => "l1\nl2\nl3\nl4"}}

      assert "l2\nl3" =
               read.(%{"path" => "notes.md", "offset" => 2, "limit" => 2}, %{
                 state: state,
                 tool_call_id: "t1"
               })

      assert "l3\nl4" =
               read.(%{"path" => "notes.md", "offset" => 3}, %{state: state, tool_call_id: "t1"})

      assert "l1" =
               read.(%{"path" => "notes.md", "limit" => 1}, %{state: state, tool_call_id: "t1"})
    end

    test "missing file lists the existing paths" do
      %Tool{function: read} = Enum.find(Filesystem.new().tools, &(&1.name == "read_file"))

      assert "File not found: nope.md. Files: a.txt, b.txt" =
               read.(%{"path" => "nope.md"}, %{
                 state: %{workspace: %{"b.txt" => "x", "a.txt" => "y"}},
                 tool_call_id: "t1"
               })
    end

    test "tombstoned file reads as not found" do
      %Tool{function: read} = Enum.find(Filesystem.new().tools, &(&1.name == "read_file"))

      assert "File not found: gone.txt. Files: (none)" =
               read.(%{"path" => "gone.txt"}, %{
                 state: %{workspace: %{"gone.txt" => nil}},
                 tool_call_id: "t1"
               })
    end
  end

  describe "write_file" do
    test "returns a command updating the workspace and replying to the call" do
      %Tool{function: write} = Enum.find(Filesystem.new().tools, &(&1.name == "write_file"))

      assert %Command{
               update: %{
                 workspace: %{"notes.md" => "hello"},
                 messages: [
                   %Message.Tool{content: "Wrote notes.md (5 bytes)", tool_call_id: "t1"}
                 ]
               }
             } =
               write.(%{"path" => "notes.md", "content" => "hello"}, %{
                 state: %{workspace: %{}},
                 tool_call_id: "t1"
               })
    end

    test "rejects content beyond max_file_bytes" do
      %Tool{function: write} =
        Enum.find(Filesystem.new(max_file_bytes: 4).tools, &(&1.name == "write_file"))

      assert "File exceeds max size of 4 bytes (got 5 bytes)." =
               write.(%{"path" => "notes.md", "content" => "hello"}, %{
                 state: %{workspace: %{}},
                 tool_call_id: "t1"
               })
    end

    test "rejects a new file beyond max_files but allows overwrites" do
      %Tool{function: write} =
        Enum.find(Filesystem.new(max_files: 1).tools, &(&1.name == "write_file"))

      state = %{workspace: %{"a.txt" => "one"}}

      assert "Workspace is full (max 1 files). Overwrite or reuse an existing file." =
               write.(%{"path" => "b.txt", "content" => "two"}, %{
                 state: state,
                 tool_call_id: "t1"
               })

      assert %Command{update: %{workspace: %{"a.txt" => "updated"}}} =
               write.(%{"path" => "a.txt", "content" => "updated"}, %{
                 state: state,
                 tool_call_id: "t1"
               })
    end

    test "tombstoned files do not count against max_files" do
      %Tool{function: write} =
        Enum.find(Filesystem.new(max_files: 1).tools, &(&1.name == "write_file"))

      assert %Command{update: %{workspace: %{"b.txt" => "two"}}} =
               write.(%{"path" => "b.txt", "content" => "two"}, %{
                 state: %{workspace: %{"a.txt" => nil}},
                 tool_call_id: "t1"
               })
    end
  end

  describe "edit_file" do
    test "replaces a unique anchor and returns the updated file" do
      %Tool{function: edit} = Enum.find(Filesystem.new().tools, &(&1.name == "edit_file"))

      assert %Command{
               update: %{
                 workspace: %{"draft.md" => "hello world"},
                 messages: [
                   %Message.Tool{content: "Edited draft.md (11 bytes)", tool_call_id: "t1"}
                 ]
               }
             } =
               edit.(
                 %{"path" => "draft.md", "old_string" => "there", "new_string" => "world"},
                 %{state: %{workspace: %{"draft.md" => "hello there"}}, tool_call_id: "t1"}
               )
    end

    test "missing file lists the existing paths" do
      %Tool{function: edit} = Enum.find(Filesystem.new().tools, &(&1.name == "edit_file"))

      assert "File not found: nope.md. Files: draft.md" =
               edit.(
                 %{"path" => "nope.md", "old_string" => "a", "new_string" => "b"},
                 %{state: %{workspace: %{"draft.md" => "hi"}}, tool_call_id: "t1"}
               )
    end

    test "zero matches returns an error" do
      %Tool{function: edit} = Enum.find(Filesystem.new().tools, &(&1.name == "edit_file"))

      assert "old_string not found in draft.md: \"missing\"" =
               edit.(
                 %{"path" => "draft.md", "old_string" => "missing", "new_string" => "x"},
                 %{state: %{workspace: %{"draft.md" => "hello there"}}, tool_call_id: "t1"}
               )
    end

    test "multiple matches tells the model to widen the anchor" do
      %Tool{function: edit} = Enum.find(Filesystem.new().tools, &(&1.name == "edit_file"))

      assert "old_string matches 2 times in draft.md. " <>
               "Widen the anchor with more surrounding text so it matches exactly once." =
               edit.(
                 %{"path" => "draft.md", "old_string" => "ha", "new_string" => "x"},
                 %{state: %{workspace: %{"draft.md" => "ha ha"}}, tool_call_id: "t1"}
               )
    end

    test "rejects an edit growing the file beyond max_file_bytes" do
      %Tool{function: edit} =
        Enum.find(Filesystem.new(max_file_bytes: 5).tools, &(&1.name == "edit_file"))

      assert "File exceeds max size of 5 bytes (got 8 bytes)." =
               edit.(
                 %{"path" => "draft.md", "old_string" => "hi", "new_string" => "hi there"},
                 %{state: %{workspace: %{"draft.md" => "hi"}}, tool_call_id: "t1"}
               )
    end

    test "rejects an empty old_string" do
      %Tool{function: edit} = Enum.find(Filesystem.new().tools, &(&1.name == "edit_file"))

      assert "old_string must not be empty." =
               edit.(
                 %{"path" => "draft.md", "old_string" => "", "new_string" => "x"},
                 %{state: %{workspace: %{"draft.md" => "hi"}}, tool_call_id: "t1"}
               )
    end
  end

  describe "glob" do
    test "* matches within a segment only" do
      %Tool{function: glob} = Enum.find(Filesystem.new().tools, &(&1.name == "glob"))

      workspace = %{"a.txt" => "1", "b.md" => "2", "dir/c.txt" => "3"}

      assert "a.txt" =
               glob.(%{"pattern" => "*.txt"}, %{
                 state: %{workspace: workspace},
                 tool_call_id: "t1"
               })
    end

    test "** matches across segments, sorted" do
      %Tool{function: glob} = Enum.find(Filesystem.new().tools, &(&1.name == "glob"))

      workspace = %{"dir/c.txt" => "3", "a.txt" => "1", "b.md" => "2"}

      assert "a.txt\ndir/c.txt" =
               glob.(%{"pattern" => "**.txt"}, %{
                 state: %{workspace: workspace},
                 tool_call_id: "t1"
               })
    end

    test "skips tombstoned files and reports empty results" do
      %Tool{function: glob} = Enum.find(Filesystem.new().tools, &(&1.name == "glob"))

      assert "No files match *.txt" =
               glob.(%{"pattern" => "*.txt"}, %{
                 state: %{workspace: %{"a.txt" => nil}},
                 tool_call_id: "t1"
               })
    end
  end

  describe "grep" do
    test "returns path:line_no: line entries across sorted files" do
      %Tool{function: grep} = Enum.find(Filesystem.new().tools, &(&1.name == "grep"))

      workspace = %{"b.txt" => "nope\nTODO b", "a.txt" => "TODO a"}

      assert "a.txt:1: TODO a\nb.txt:2: TODO b" =
               grep.(%{"pattern" => "TODO"}, %{
                 state: %{workspace: workspace},
                 tool_call_id: "t1"
               })
    end

    test "path_glob scopes which files are searched" do
      %Tool{function: grep} = Enum.find(Filesystem.new().tools, &(&1.name == "grep"))

      workspace = %{"a.txt" => "TODO a", "b.md" => "TODO b"}

      assert "b.md:1: TODO b" =
               grep.(%{"pattern" => "TODO", "path_glob" => "*.md"}, %{
                 state: %{workspace: workspace},
                 tool_call_id: "t1"
               })
    end

    test "reports no matches" do
      %Tool{function: grep} = Enum.find(Filesystem.new().tools, &(&1.name == "grep"))

      assert "No matches." =
               grep.(%{"pattern" => "TODO"}, %{
                 state: %{workspace: %{"a.txt" => "nothing"}},
                 tool_call_id: "t1"
               })
    end

    test "invalid regex returns an error string" do
      %Tool{function: grep} = Enum.find(Filesystem.new().tools, &(&1.name == "grep"))

      assert "Invalid regex: " <> _rest =
               grep.(%{"pattern" => "["}, %{
                 state: %{workspace: %{"a.txt" => "x"}},
                 tool_call_id: "t1"
               })
    end

    test "caps output at 100 lines and marks truncation" do
      %Tool{function: grep} = Enum.find(Filesystem.new().tools, &(&1.name == "grep"))

      content = Enum.map_join(1..150, "\n", fn n -> "match #{n}" end)

      result =
        grep.(%{"pattern" => "match"}, %{
          state: %{workspace: %{"big.txt" => content}},
          tool_call_id: "t1"
        })

      assert String.ends_with?(result, "(truncated)")
      assert 101 = result |> String.split("\n") |> length()
      assert String.contains?(result, "big.txt:100: match 100")
      refute String.contains?(result, "match 101")
    end
  end
end
