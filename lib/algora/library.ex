defmodule Algora.Library do
  @moduledoc """
  The Library context.
  """

  require Logger
  import Ecto.Query, warn: false
  import Ecto.Changeset
  alias Algora.Accounts.User
  alias Algora.{Repo, Accounts, Storage, MP4Stat}
  alias Algora.Library.{Channel, Video, Events, Subtitle}

  @pubsub Algora.PubSub
  @max_videos 100

  def subscribe_to_studio() do
    Phoenix.PubSub.subscribe(@pubsub, topic_studio())
  end

  def subscribe_to_livestreams() do
    Phoenix.PubSub.subscribe(@pubsub, topic_livestreams())
  end

  def subscribe_to_channel(%Channel{} = channel) do
    Phoenix.PubSub.subscribe(@pubsub, topic(channel.user_id))
  end

  def init_livestream!() do
    %Video{
      title: "",
      duration: 0,
      type: :livestream,
      format: :hls,
      is_live: true,
      visibility: :unlisted
    }
    |> change()
    |> Video.put_video_path(:hls)
    |> Repo.insert!()
  end

  def transmux_to_mp4(%Video{} = video, cb) do
    mp4_basename = Slug.slugify("#{Date.to_string(video.inserted_at)}-#{video.title}")

    mp4_video =
      %Video{
        title: video.title,
        duration: video.duration,
        type: :vod,
        format: :mp4,
        is_live: false,
        visibility: :unlisted,
        user_id: video.user_id,
        transmuxed_from_id: video.id,
        thumbnail_url: video.thumbnail_url
      }
      |> change()
      |> Video.put_video_path(:mp4, mp4_basename)

    %{uuid: mp4_uuid, filename: mp4_filename} = mp4_video.changes

    dir = Path.join(System.tmp_dir!(), mp4_uuid)
    File.mkdir_p!(dir)
    dst_path = Path.join(dir, mp4_filename)

    System.cmd("ffmpeg", ["-i", video.url, "-c", "copy", dst_path])
    Storage.upload_file(dst_path, "#{mp4_uuid}/#{mp4_filename}", cb)
    Repo.insert!(mp4_video)
  end

  def transmux_to_hls(%Video{} = _video, _cb) do
    todo = true
    src_path = ""
    uuid = ""
    filename = ""

    dir = Path.join(System.tmp_dir!(), uuid)
    File.mkdir_p!(dir)
    dst_path = Path.join(dir, filename)

    if !todo do
      System.cmd("ffmpeg", [
        "-i",
        src_path,
        "-c",
        "copy",
        "-start_number",
        0,
        "-hls_time",
        2,
        "-hls_list_size",
        0,
        "-f",
        "hls",
        dst_path
      ])
    end

    {:error, :not_implemented}
  end

  def get_mp4_video(id) do
    from(v in Video,
      where: v.format == :mp4 and (v.transmuxed_from_id == ^id or v.id == ^id),
      join: u in User,
      on: v.user_id == u.id,
      select_merge: %{channel_handle: u.handle, channel_name: u.name}
    )
    |> Repo.one()
  end

  def toggle_streamer_live(%Video{} = video, is_live) do
    video = get_video!(video.id)
    user = Accounts.get_user!(video.user_id)

    if user.visibility == :public do
      Repo.update_all(from(u in Accounts.User, where: u.id == ^video.user_id),
        set: [is_live: is_live]
      )
    end

    Repo.update_all(
      from(v in Video,
        where: v.user_id == ^video.user_id and (v.id != ^video.id or not (^is_live))
      ),
      set: [is_live: false]
    )

    video = get_video!(video.id)

    video =
      with false <- is_live,
           {:ok, duration} <- get_duration(video),
           {:ok, video} <- video |> change() |> put_change(:duration, duration) |> Repo.update() do
        video
      else
        _ -> video
      end

    msg =
      case is_live do
        true -> %Events.LivestreamStarted{video: video}
        false -> %Events.LivestreamEnded{video: video}
      end

    Phoenix.PubSub.broadcast!(@pubsub, topic_livestreams(), {__MODULE__, msg})

    sink_url = Algora.config([:event_sink, :url])

    if sink_url && user.visibility == :public do
      identity =
        from(i in Algora.Accounts.Identity,
          join: u in assoc(i, :user),
          where: u.id == ^video.user_id and i.provider == "github",
          order_by: [asc: i.inserted_at]
        )
        |> Repo.one()
        |> Repo.preload(:user)

      body =
        Jason.encode_to_iodata!(%{
          event_kind: if(is_live, do: :livestream_started, else: :livestream_ended),
          stream_id: video.uuid,
          url: "#{AlgoraWeb.Endpoint.url()}/#{identity.user.handle}",
          github_user: %{
            id: String.to_integer(identity.provider_id),
            login: identity.provider_login
          }
        })

      Finch.build(:post, sink_url, [{"content-type", "application/json"}], body)
      |> Finch.request(Algora.Finch)
    end
  end

  defp get_playlist(%Video{} = video) do
    url = "#{video.url_root}/index.m3u8"

    with {:ok, resp} <- Finch.build(:get, url) |> Finch.request(Algora.Finch) do
      ExM3U8.deserialize_playlist(resp.body, [])
    end
  end

  defp get_media_playlist(%Video{} = video, uri) do
    url = "#{video.url_root}/#{uri}"

    with {:ok, resp} <- Finch.build(:get, url) |> Finch.request(Algora.Finch) do
      ExM3U8.deserialize_media_playlist(resp.body, [])
    end
  end

  defp get_media_playlist(%Video{} = video) do
    with {:ok, playlist} <- get_playlist(video) do
      uri = playlist.items |> Enum.find(&match?(%{uri: _}, &1)) |> then(& &1.uri)
      get_media_playlist(video, uri)
    end
  end

  def get_duration(%Video{format: :hls} = video) do
    with {:ok, playlist} <- get_media_playlist(video) do
      duration =
        playlist.timeline
        |> Enum.filter(&match?(%{duration: _}, &1))
        |> Enum.reduce(0, fn x, acc -> acc + x.duration end)

      {:ok, round(duration)}
    end
  end

  def get_duration(_video) do
    {:error, :not_implemented}
  end

  def to_hhmmss(duration) when is_integer(duration) do
    hours = div(duration, 60 * 60)
    minutes = div(duration - hours * 60 * 60, 60)
    seconds = rem(duration - hours * 60 * 60 - minutes * 60, 60)

    if(hours == 0, do: [minutes, seconds], else: [hours, minutes, seconds])
    |> Enum.map_join(":", fn count -> String.pad_leading("#{count}", 2, ["0"]) end)
  end

  def to_hhmmss(duration) when is_float(duration) do
    to_hhmmss(trunc(duration))
  end

  def unsubscribe_to_channel(%Channel{} = channel) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(channel.user_id))
  end

  defp create_thumbnail(%Video{} = video, contents) do
    src_path = Path.join(System.tmp_dir!(), "#{video.uuid}.mp4")
    dst_path = Path.join(System.tmp_dir!(), "#{video.uuid}.jpeg")

    with :ok <- File.write(src_path, contents),
         :ok <- Thumbnex.create_thumbnail(src_path, dst_path) do
      File.read(dst_path)
    end
  end

  def store_thumbnail(%Video{} = video, contents) do
    with {:ok, thumbnail} <- create_thumbnail(video, contents),
         {:ok, _} <- Storage.upload_contents("#{video.uuid}/index.jpeg", thumbnail) do
      :ok
    end
  end

  def reconcile_livestream(%Video{} = video, stream_key) do
    user =
      Accounts.get_user_by!(stream_key: stream_key)

    result =
      Repo.update_all(from(v in Video, where: v.id == ^video.id),
        set: [user_id: user.id, title: user.channel_tagline, visibility: user.visibility]
      )

    case result do
      {1, _} ->
        {:ok, video}

      _ ->
        {:error, :invalid}
    end
  end

  def list_videos(limit \\ 100) do
    from(v in Video,
      join: u in User,
      on: v.user_id == u.id,
      limit: ^limit,
      where:
        is_nil(v.transmuxed_from_id) and
          v.visibility == :public and
          is_nil(v.vertical_thumbnail_url) and
          (v.is_live == true or v.duration >= 120 or v.type == :vod),
      select_merge: %{channel_handle: u.handle, channel_name: u.name}
    )
    |> order_by_inserted(:desc)
    |> Repo.all()
  end

  def list_shorts(limit \\ 100) do
    from(v in Video,
      join: u in User,
      on: v.user_id == u.id,
      limit: ^limit,
      where:
        is_nil(v.transmuxed_from_id) and v.visibility == :public and
          not is_nil(v.vertical_thumbnail_url),
      select_merge: %{channel_handle: u.handle, channel_name: u.name}
    )
    |> order_by_inserted(:desc)
    |> Repo.all()
  end

  def list_channel_videos(%Channel{} = channel, limit \\ 100) do
    from(v in Video,
      limit: ^limit,
      join: u in User,
      on: v.user_id == u.id,
      select_merge: %{channel_handle: u.handle, channel_name: u.name},
      where: is_nil(v.transmuxed_from_id) and v.user_id == ^channel.user_id
    )
    |> order_by_inserted(:desc)
    |> Repo.all()
  end

  def list_studio_videos(%Channel{} = channel, limit \\ 100) do
    from(v in Video,
      limit: ^limit,
      join: u in User,
      on: v.user_id == u.id,
      select_merge: %{channel_handle: u.handle, channel_name: u.name},
      where: is_nil(v.transmuxed_from_id) and v.user_id == ^channel.user_id
    )
    |> order_by_inserted(:desc)
    |> Repo.all()
  end

  def list_active_channels(opts) do
    from(u in Algora.Accounts.User,
      where: u.is_live,
      limit: ^Keyword.fetch!(opts, :limit),
      order_by: [desc: u.updated_at],
      select: struct(u, [:id, :handle, :channel_tagline, :avatar_url, :external_homepage_url])
    )
    |> Repo.all()
    |> Enum.map(&get_channel!/1)
  end

  def get_channel!(%Accounts.User{} = user) do
    %Channel{
      user_id: user.id,
      handle: user.handle,
      name: user.name || user.handle,
      tagline: user.channel_tagline,
      avatar_url: user.avatar_url,
      external_homepage_url: user.external_homepage_url,
      is_live: user.is_live,
      bounties_count: user.bounties_count,
      orgs_contributed: user.orgs_contributed,
      tech: user.tech
    }
  end

  def owns_channel?(%Accounts.User{} = user, %Channel{} = channel) do
    user.id == channel.user_id
  end

  def player_type(%Video{format: :mp4}), do: "video/mp4"
  def player_type(%Video{format: :hls}), do: "application/x-mpegURL"
  def player_type(%Video{format: :youtube}), do: "video/youtube"

  def get_video!(id),
    do:
      from(v in Video,
        where: v.id == ^id,
        join: u in User,
        on: v.user_id == u.id,
        select_merge: %{channel_handle: u.handle, channel_name: u.name}
      )
      |> Repo.one!()

  def update_video(%Video{} = video, attrs) do
    video
    |> Video.changeset(attrs)
    |> Repo.update()
  end

  def change_video(video_or_changeset, attrs \\ %{})

  def change_video(%Video{} = video, attrs) do
    Video.changeset(video, attrs)
  end

  @keep_changes []
  def change_video(%Ecto.Changeset{} = prev_changeset, attrs) do
    %Video{}
    |> change_video(attrs)
    |> Ecto.Changeset.change(Map.take(prev_changeset.changes, @keep_changes))
  end

  defp order_by_inserted(%Ecto.Query{} = query, direction) when direction in [:asc, :desc] do
    from(s in query, order_by: [{^direction, s.inserted_at}])
  end

  def store_mp4(%Video{} = video, tmp_path) do
    File.mkdir_p!(Path.dirname(video.mp4_filepath))
    File.cp!(tmp_path, video.mp4_filepath)
  end

  def put_stats(%Ecto.Changeset{} = changeset, %MP4Stat{} = stat) do
    chset = Video.put_stats(changeset, stat)

    if error = chset.errors[:duration] do
      {:error, %{duration: error}}
    else
      {:ok, chset}
    end
  end

  def import_videos(%Accounts.User{} = user, changesets, consume_file)
      when is_map(changesets) and is_function(consume_file, 2) do
    # refetch user for fresh video count
    user = Accounts.get_user!(user.id)

    multi =
      Ecto.Multi.new()
      # TODO: lock playlist
      # |> lock_playlist(user.id)
      |> Ecto.Multi.run(:starting_position, fn repo, _changes ->
        count = repo.one(from s in Video, where: s.user_id == ^user.id, select: count(s.id))
        {:ok, count - 1}
      end)

    multi =
      changesets
      |> Enum.with_index()
      |> Enum.reduce(multi, fn {{ref, chset}, i}, acc ->
        Ecto.Multi.insert(acc, {:video, ref}, fn %{starting_position: pos_start} ->
          chset
          |> Video.put_user(user)
          |> Video.put_video_path(:mp4)
          |> Ecto.Changeset.put_change(:position, pos_start + i + 1)
        end)
      end)
      |> Ecto.Multi.run(:valid_videos_count, fn _repo, changes ->
        new_videos_count =
          changes |> Enum.filter(&match?({{:video, _ref}, _}, &1)) |> Enum.count()

        validate_videos_limit(user.videos_count, new_videos_count)
      end)
      |> Ecto.Multi.update_all(
        :update_videos_count,
        fn %{valid_videos_count: new_count} ->
          from(u in Accounts.User,
            where: u.id == ^user.id and u.videos_count == ^user.videos_count,
            update: [inc: [videos_count: ^new_count]]
          )
        end,
        []
      )
      |> Ecto.Multi.run(:is_videos_count_updated?, fn _repo, %{update_videos_count: result} ->
        case result do
          {1, _} -> {:ok, user}
          _ -> {:error, :invalid}
        end
      end)

    case Algora.Repo.transaction(multi) do
      {:ok, results} ->
        videos =
          results
          |> Enum.filter(&match?({{:video, _ref}, _}, &1))
          |> Enum.map(fn {{:video, ref}, video} ->
            consume_file.(ref, fn tmp_path -> store_mp4(video, tmp_path) end)
            {ref, video}
          end)

        broadcast_imported(user, videos)

        {:ok, Enum.into(videos, %{})}

      {:error, failed_op, failed_val, _changes} ->
        failed_op =
          case failed_op do
            {:video, _number} -> "Invalid video (#{failed_val.changes.title})"
            :is_videos_count_updated? -> :invalid
            failed_op -> failed_op
          end

        {:error, {failed_op, failed_val}}
    end
  end

  defp topic(user_id) when is_integer(user_id), do: "channel:#{user_id}"

  def topic_livestreams(), do: "livestreams"

  def topic_studio(), do: "studio"

  def list_subtitles(%Video{} = video) do
    from(s in Subtitle, where: s.video_id == ^video.id, order_by: [asc: s.start])
    |> Repo.all()
  end

  def get_subtitle!(id), do: Repo.get!(Subtitle, id)

  def create_subtitle(%Video{} = video, attrs \\ %{}) do
    %Subtitle{video_id: video.id}
    |> Subtitle.changeset(attrs)
    |> Repo.insert()
  end

  def update_subtitle(%Subtitle{} = subtitle, attrs) do
    subtitle
    |> Subtitle.changeset(attrs)
    |> Repo.update()
  end

  def delete_subtitle(%Subtitle{} = subtitle) do
    Repo.delete(subtitle)
  end

  def change_subtitle(%Subtitle{} = subtitle, attrs \\ %{}) do
    Subtitle.changeset(subtitle, attrs)
  end

  def save_subtitle(sub) do
    %Subtitle{id: sub["id"]}
    |> Subtitle.changeset(%{start: sub["start"], end: sub["end"], body: sub["body"]})
    |> Repo.update!()
  end

  def save_subtitles(data) do
    Jason.decode!(data)
    |> Enum.take(100)
    |> Enum.map(&save_subtitle/1)
    |> length
  end

  def parse_file_name(name) do
    case Regex.split(~r/[-–]/, Path.rootname(name), parts: 2) do
      [title] -> %{title: String.trim(title), artist: nil}
      [title, artist] -> %{title: String.trim(title), artist: String.trim(artist)}
    end
  end

  defp broadcast!(topic, msg) do
    Phoenix.PubSub.broadcast!(@pubsub, topic, {__MODULE__, msg})
  end

  defp broadcast_imported(%Accounts.User{} = user, videos) do
    videos = Enum.map(videos, fn {_ref, video} -> video end)
    broadcast!(user.id, %Events.VideosImported{user_id: user.id, videos: videos})
  end

  def broadcast_transmuxing_progressed!(video, pct) do
    broadcast!(topic_studio(), %Events.TransmuxingProgressed{video: video, pct: pct})
  end

  def broadcast_transmuxing_completed!(video, url) do
    broadcast!(topic_studio(), %Events.TransmuxingCompleted{video: video, url: url})
  end

  defp validate_videos_limit(user_videos, new_videos_count) do
    if user_videos + new_videos_count <= @max_videos do
      {:ok, new_videos_count}
    else
      {:error, :videos_limit_exceeded}
    end
  end
end
