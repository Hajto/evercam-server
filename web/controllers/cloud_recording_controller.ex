defmodule EvercamMedia.CloudRecordingController do
  use EvercamMedia.Web, :controller
  alias EvercamMedia.ErrorView
  alias EvercamMedia.Snapshot.WorkerSupervisor
  import EvercamMedia.Validation.CloudRecording

  def show(conn, %{"id" => exid}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.by_exid_with_associations(exid)

    with :ok <- ensure_camera_exists(camera, exid, conn),
         :ok <- ensure_can_edit(current_user, camera, conn),
         do: camera.cloud_recordings |> render_cloud_recording(conn)
  end

  def create(conn, %{"id" => exid} = params) do
    current_user = conn.assigns[:current_user]
    camera = Camera.by_exid_with_associations(exid)

    with :ok <- ensure_camera_exists(camera, exid, conn),
         :ok <- ensure_can_edit(current_user, camera, conn),
         :ok <- validate_params(params) |> ensure_params(conn)
    do
      cr_params = %{
        camera_id: camera.id,
        frequency: params["frequency"],
        storage_duration: params["storage_duration"],
        status: params["status"],
        schedule: get_json(params["schedule"])
      }

      old_cloud_recording = camera.cloud_recordings || %CloudRecording{}
      action_log = get_action_log(camera.cloud_recordings)
      case old_cloud_recording |> CloudRecording.changeset(cr_params) |> Repo.insert_or_update do
        {:ok, cloud_recording} ->
          camera = camera |> Repo.preload(:cloud_recordings, force: true)
          Camera.invalidate_camera(camera)
          exid
          |> String.to_atom
          |> Process.whereis
          |> WorkerSupervisor.update_worker(camera)

          CameraActivity.log_activity(current_user, camera, "cloud recordings #{action_log}",
            %{
              ip: user_request_ip(conn),
              cr_settings: %{
                old: set_settings(old_cloud_recording),
                new: set_settings(cloud_recording)
                },
              }
          )
          send_email_on_cr_change(Application.get_env(:evercam_media, :run_spawn), current_user, camera, cloud_recording, old_cloud_recording, user_request_ip(conn))
          conn
          |> render("cloud_recording.json", %{cloud_recording: cloud_recording})
        {:error, changeset} ->
          render_error(conn, 400, changeset)
      end
    end
  end

  def nvr_days(conn, %{"id" => exid, "year" => year, "month" => month}) do
    camera = Camera.by_exid_with_associations(exid)

    with :ok <- ensure_camera_exists(camera, exid, conn)
    do
      ip = Camera.host(camera, "external")
      port = Camera.port(camera, "external", "http")
      cam_username = Camera.username(camera)
      cam_password = Camera.password(camera)
      url = camera.vendor_model.h264_url
      channel = url |> String.split("/channels/") |> List.last |> String.split("/") |> List.first

      case EvercamMedia.HikvisionNVR.get_recording_days(ip, port, cam_username, cam_password, channel, year, month) do
        {:ok, body} ->
          days = EvercamMedia.XMLParser.parse_xml(body, '/trackDailyDistribution/dayList/day/dayOfMonth')
          records = EvercamMedia.XMLParser.parse_xml(body, '/trackDailyDistribution/dayList/day/record')
          record_days =
            days
            |> Enum.with_index
            |> Enum.map(fn(item) ->
              {day, index} = item
              case records |> Enum.at(index) do
                "true" -> day
                "false" -> ""
              end
            end)
            |> Enum.uniq
          json(conn, %{days: record_days})
        {:error} -> render_error(conn, 404, "No recordings found")
      end
    end
  end

  def nvr_hours(conn, %{"id" => exid, "year" => year, "month" => month, "day" => day}) do
    camera = Camera.by_exid_with_associations(exid)

    with :ok <- ensure_camera_exists(camera, exid, conn)
    do
      ip = Camera.host(camera, "external")
      port = Camera.port(camera, "external", "http")
      cam_username = Camera.username(camera)
      cam_password = Camera.password(camera)
      url = camera.vendor_model.h264_url
      timezone = Camera.get_timezone(camera)
      channel = url |> String.split("/channels/") |> List.last |> String.split("/") |> List.first
      date = "#{year}-#{month}-#{day}"
      starttime = "#{date}T00:00:00Z"
      endtime = "#{date}T23:59:59Z"
      current_datetime = Calendar.DateTime.now_utc |> Calendar.DateTime.shift_zone!(timezone)

      case EvercamMedia.HikvisionNVR.get_stream_urls(camera.exid, ip, port, cam_username, cam_password, channel, starttime, endtime) do
        {:ok, body} ->
          starttime_list = EvercamMedia.XMLParser.parse_xml(body, '/CMSearchResult/matchList/searchMatchItem/timeSpan/startTime')
          endtime_list = EvercamMedia.XMLParser.parse_xml(body, '/CMSearchResult/matchList/searchMatchItem/timeSpan/endTime')
          meta_data = EvercamMedia.XMLParser.parse_single(body, '/CMSearchResult/matchList/searchMatchItem[1]/metadataMatches/metadataDescriptor')
          hours = parse_hours(String.contains?(meta_data, "motion"), starttime_list, endtime_list, date, current_datetime)

          json(conn, %{hours: hours})
        {:error} -> render_error(conn, 404, "No recordings found")
      end
    end
  end

  def hikvision_nvr(conn, %{"id" => exid, "starttime" => starttime, "endtime" => endtime}) do
    camera = Camera.by_exid_with_associations(exid)

    with :ok <- ensure_camera_exists(camera, exid, conn)
    do
      ip = Camera.host(camera, "external")
      port = Camera.port(camera, "external", "rtsp")
      cam_username = Camera.username(camera)
      cam_password = Camera.password(camera)
      url = camera.vendor_model.h264_url
      channel = url |> String.split("/channels/") |> List.last |> String.split("/") |> List.first
      case EvercamMedia.HikvisionNVR.publish_stream_from_rtsp(camera.exid, ip, port, cam_username, cam_password, channel, convert_timestamp(starttime), convert_timestamp(endtime)) do
        {:ok} -> json(conn, %{message: "Streaming started."})
        {:error} -> render_error(conn, 404, "No recordings found")
      end
    end
  end

  def stop(conn, %{"id" => exid}) do
    camera = Camera.by_exid_with_associations(exid)
    with :ok <- ensure_camera_exists(camera, exid, conn)
    do
      ip = Camera.host(camera, "external")
      port = Camera.port(camera, "external", "rtsp")
      cam_username = Camera.username(camera)
      cam_password = Camera.password(camera)
      case EvercamMedia.HikvisionNVR.stop(camera.exid, ip, port, cam_username, cam_password) do
        {:ok} -> json(conn, %{message: "Streaming started."})
        {:error} -> render_error(conn, 404, "No recordings found")
      end
    end
  end

  def get_recording_times(conn, %{"id" => exid, "starttime" => starttime, "endtime" => endtime}) do
    camera = Camera.by_exid_with_associations(exid)

    with :ok <- ensure_camera_exists(camera, exid, conn)
    do
      ip = Camera.host(camera, "external")
      port = Camera.port(camera, "external", "http")
      cam_username = Camera.username(camera)
      cam_password = Camera.password(camera)
      url = camera.vendor_model.h264_url
      channel = url |> String.split("/channels/") |> List.last |> String.split("/") |> List.first
      case EvercamMedia.HikvisionNVR.get_stream_urls(camera.exid, ip, port, cam_username, cam_password, channel, convert_timestamp_to_rfc(starttime), convert_timestamp_to_rfc(endtime)) do
        {:ok, body} ->
          starttime_list = EvercamMedia.XMLParser.parse_xml(body, '/CMSearchResult/matchList/searchMatchItem/timeSpan/startTime')
          endtime_list = EvercamMedia.XMLParser.parse_xml(body, '/CMSearchResult/matchList/searchMatchItem/timeSpan/endTime')
          meta_data = EvercamMedia.XMLParser.parse_single(body, '/CMSearchResult/matchList/searchMatchItem[1]/metadataMatches/metadataDescriptor')

          cond do
            Enum.count(starttime_list) > 0 ->
              times_list = get_times_list(String.contains?(meta_data, "motion"), starttime_list, endtime_list)
              json(conn, %{times_list: times_list})
            true ->
              render_error(conn, 404, "No recordings found")
          end

        {:error} -> render_error(conn, 404, "No recordings found")
      end
    end
  end

  defp get_times_list(true, starttime_list, endtime_list) do
    starttime_list
    |> Enum.with_index
    |> Enum.map(fn(item) ->
      {timestamp, index} = item
      stime = String.replace(timestamp, "T", " ") |> String.replace("Z", "")
      etime = endtime_list |> Enum.at(index) |> String.replace("T", " ") |> String.replace("Z", "")
      [stime, 1, etime]
    end)
  end
  defp get_times_list(false, starttime_list, endtime_list) do
    starttime_list
    |> Enum.with_index
    |> Enum.reduce([], fn(item, times_list) ->
      {timestamp, index} = item
      starttime = convert_timestap_from_rfc(timestamp)
      endtime = convert_timestap_from_rfc(Enum.at(endtime_list, index))
      {:ok, seconds, _, _} = Calendar.DateTime.diff(endtime, starttime)

      times_list ++ get_timespan_chunk(starttime, endtime, [], seconds)
    end)
  end

  defp get_timespan_chunk(starttime, endtime, times_list, seconds) when seconds > 0 do
    cond do
      seconds > 299 ->
        starttime_str = starttime |> Calendar.Strftime.strftime!("%Y-%m-%d %H:%M:%S")
        endtime_str = starttime |> Calendar.DateTime.advance!(299) |> Calendar.Strftime.strftime!("%Y-%m-%d %H:%M:%S")
        times_list = times_list ++ [["#{starttime_str}",1,"#{endtime_str}"]]
        adv_starttime = Calendar.DateTime.advance!(starttime, 300)
        get_timespan_chunk(adv_starttime, endtime, times_list, seconds - 300)
      true ->
        starttime_str = starttime |> Calendar.Strftime.strftime!("%Y-%m-%d %H:%M:%S")
        endtime_str = endtime |> Calendar.Strftime.strftime!("%Y-%m-%d %H:%M:%S")
        times_list ++ [["#{starttime_str}",1,"#{endtime_str}"]]
    end
  end
  defp get_timespan_chunk(_starttime, _endtime, times_list, _seconds), do: times_list

  defp parse_hours(true, starttime_list, _endtime_list, date, current_datetime) do
    current_date = current_datetime |> Calendar.Strftime.strftime!("%Y-%m-%d")
    ehour =
      cond do
        date == current_date ->
          current_datetime |> Calendar.Strftime.strftime!("%H") |> String.to_integer
        true ->
          23
      end
    shour = starttime_list |> List.first |> get_hour_from_timestap
    extract_hours([], shour, ehour)
  end
  defp parse_hours(false, starttime_list, endtime_list, _date, _current_date) do
    starttime_list
    |> Enum.with_index
    |> Enum.reduce([], fn(item, hours) ->
      {timestamp, index} = item
      shour = get_hour_from_timestap(timestamp)
      ehour = get_hour_from_timestap(Enum.at(endtime_list, index))
      hours ++ extract_hours([], shour, ehour)
    end)
    |> List.flatten
    |> Enum.uniq
  end

  defp extract_hours(hours, shour, ehour) when shour <= ehour do
    extract_hours(hours ++ [shour], shour + 1, ehour)
  end
  defp extract_hours(hours, _shour, _ehour) do
    hours
  end

  defp convert_timestamp_to_rfc(timestamp) do
    timestamp
    |> String.to_integer
    |> Calendar.DateTime.Parse.unix!
    |> Calendar.Strftime.strftime!("%Y-%m-%dT%H:%M:%SZ")
  end

  defp convert_timestamp(timestamp) do
    timestamp
    |> String.to_integer
    |> Calendar.DateTime.Parse.unix!
    |> Calendar.Strftime.strftime!("%Y%m%dT%H%M%SZ")
  end

  defp convert_timestap_from_rfc(timestamp) do
    case Calendar.DateTime.Parse.rfc3339_utc(timestamp) do
      {:ok, datetime} -> datetime
      {:bad_format, nil} -> nil
    end
  end

  defp get_hour_from_timestap(timestamp) do
    case Calendar.DateTime.Parse.rfc3339_utc(timestamp) do
      {:ok, datetime} ->
        datetime
        |> Calendar.Strftime.strftime!("%H")
        |> String.to_integer
      {:bad_format, nil} -> nil
    end
  end

  defp set_settings(cloud_recording) do
    case cloud_recording.camera_id do
      nil -> nil
      _ ->
        %{status: cloud_recording.status, storage_duration: cloud_recording.storage_duration, frequency: cloud_recording.frequency, schedule: cloud_recording.schedule}
    end
  end

  defp send_email_on_cr_change(false, _current_user, _camera, _cloud_recording, _old_cloud_recording, _user_request_ip), do: :noop
  defp send_email_on_cr_change(true, current_user, camera, cloud_recording, old_cloud_recording, user_request_ip) do
    try do
      Task.start(fn ->
        EvercamMedia.UserMailer.cr_settings_changed(current_user, camera, cloud_recording, old_cloud_recording, user_request_ip)
      end)
    catch _type, error ->
      Util.error_handler(error)
    end
  end

  defp ensure_camera_exists(nil, exid, conn) do
    conn
    |> put_status(404)
    |> render(ErrorView, "error.json", %{message: "Camera '#{exid}' not found!"})
  end
  defp ensure_camera_exists(_camera, _id, _conn), do: :ok

  defp ensure_can_edit(current_user, camera, conn) do
    if Permission.Camera.can_edit?(current_user, camera) do
      :ok
    else
      conn
      |> put_status(403)
      |> render(ErrorView, "error.json", %{message: "You don't have sufficient rights for this."})
    end
  end

  defp ensure_params(:ok, _conn), do: :ok
  defp ensure_params({:invalid, message}, conn), do: json(conn, %{error: message})

  defp get_json(schedule) do
    case Poison.decode(schedule) do
      {:ok, json} -> json
    end
  end

  defp render_cloud_recording(nil, conn), do: conn |> render("show.json", %{cloud_recording: []})
  defp render_cloud_recording(cl, conn), do: conn |> render("cloud_recording.json", %{cloud_recording: cl})

  defp get_action_log(nil), do: "created"
  defp get_action_log(_cloud_recording), do: "updated"
end
