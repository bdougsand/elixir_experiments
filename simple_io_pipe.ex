@doc """
An experiment. I didn't see anything in the standard library for piping output
from one place to another. Perhaps I missed it.

    {device, out_stream} = SimpleIOPipe.make()
    spawn(fn ->
        Enum.each(stream, fn line -> IO.puts("Read line: \#{line}") end)
        IO.puts("Finished reading stream")
    end)
    IO.write(device, "hello")
    IO.write(device, "lamppost")
    IO.write(device, "Watcha knowin'")


"""
defmodule SimpleIOPipe do
  defstruct waiting: [],
    buffered: []

  def make() do
    {:ok, stream_pid} = __MODULE__.start()
    {stream_pid, IO.stream(stream_pid, :line)}
  end

  def close(pid) do
    send(pid, :io_close)
  end

  def start() do
    {:ok, spawn(__MODULE__, :noreply_loop, [])}
  end

  def noreply_loop() do
    noreply_loop(%__MODULE__{})
  end

  def noreply_loop(state) do
    state = flush(state)
    receive do
      {:io_request, from, reply_as, req} ->
        new_state =
          case req do
            {:put_chars, _encoding, data} ->
              send(from, {:io_reply, reply_as, :ok})
              Map.update!(state, :buffered, &(&1 ++ [data]))

            {:get_line, _encoding, _prompt} ->
              Map.update!(state, :waiting, &(&1 ++ [{from, reply_as}]))

            # Doesn't implement :get_chars, :put_chars, :get_until.
          end
        noreply_loop(new_state)

      :io_close ->
        write_all(state, :eof)
    end
  end

  def write_all(state, data) do
    Enum.each(state.waiting, fn {waiter_pid, reply_as} ->
      send(waiter_pid, {:io_reply, reply_as, data})
    end)
  end

  def flush(%{waiting: w, buffered: b} = state) do
    with [{waiter_pid, reply_as} | waiters] <- w,
         [line | lines] <- b do
      send(waiter_pid, {:io_reply, reply_as, line})

      new_state = %{state | waiting: waiters, buffered: lines}
      if Enum.empty?(lines) do
        new_state
      else
        flush(new_state)
      end
    else
      _ -> state
    end
  end
end
