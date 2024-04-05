defmodule Algora.Pipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_context, socket: socket) do
    # IO.puts(DateTime.utc_now() |> DateTime.truncate(:second) |> to_string)
    # video = Library.init_livestream!()
    dir = "/tmp/tv"
    File.mkdir_p!(dir)

    spec = [
      # child(:src, %Membrane.RTMP.Source{
      #   socket: socket,
      #   validator: %Algora.MessageValidator{video_id: video.id}
      # })
      # |> child(:sink, %Membrane.File.Sink{location: Path.join(dir, "#{video.id}.rtmp")})

      # audio
      child(:src, %Algora.SourceBin{
        location: Path.join(dir, "777.rtmp")
        # socket: socket
        # validator: %Algora.MessageValidator{video_id: video.id}
      })
      |> via_out(:audio)
      |> via_in(Pad.ref(:input, :audio),
        options: [encoding: :AAC, segment_duration: Membrane.Time.seconds(2)]
      )
      |> child(:sink, %Membrane.File.Sink{location: Path.join(dir, "777-01.mp4")}),

      # |> child(:sink, %Membrane.HTTPAdaptiveStream.SinkBin{
      #   mode: :live,
      #   manifest_module: Membrane.HTTPAdaptiveStream.HLS,
      #   target_window_duration: :infinity,
      #   persist?: false,
      #   storage: %Algora.Storage{video: video}
      # }),

      # video
      get_child(:src)
      |> via_out(:video)
      |> via_in(Pad.ref(:input, :video),
        options: [encoding: :H264, segment_duration: Membrane.Time.seconds(2)]
      )
      |> get_child(:sink)
    ]

    {[spec: spec],
     %{
       socket: socket
       # , video: video
     }}
  end

  @impl true
  def handle_child_notification(
        {:socket_control_needed, _socket, _source} = notification,
        :src,
        _ctx,
        state
      ) do
    send(self(), notification)
    {[], state}
  end

  @impl true
  def handle_child_notification(:end_of_stream, _element, _ctx, state) do
    Algora.Library.toggle_streamer_live(state.video, false)
    {[], state}
  end

  @impl true
  def handle_child_notification(_notification, _element, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_info({:socket_control_needed, socket, source} = notification, _ctx, state) do
    case Membrane.RTMP.SourceBin.pass_control(socket, source) do
      :ok ->
        :ok

      {:error, :not_owner} ->
        Process.send_after(self(), notification, 200)
    end

    {[], state}
  end
end
