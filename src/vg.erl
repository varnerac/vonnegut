-module(vg).

-export([create_topic/1,
         ensure_topic/1,
         write/2,
         fetch/2,
         fetch/1]).

create_topic(Topic) ->
    {ok, _} = vonnegut_sup:create_topic(Topic),
    ok.

ensure_topic(Topic) ->
    case vonnegut_sup:create_topic(Topic) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        _ ->
            error
    end.

write(Topic, Message) when is_binary(Message) ->
    vg_active_segment:write(Topic, 0, [Message]);
write(Topic, MessageSet) when is_list(MessageSet) ->
    vg_active_segment:write(Topic, 0, MessageSet).

fetch(Topic) ->
    fetch(Topic, 0).

fetch(Topic, Offset) ->
    Partition = 0,
    {SegmentId, Position} = vg_log_segments:find_segment_offset(Topic, Partition, Offset),
    File = vg_utils:log_file(Topic, Partition, SegmentId),
    Size = filelib:file_size(File),
    {ok, Fd} = file:open(File, [read, binary, raw]),
    {ok, [Data]} = file:pread(Fd, [{Position, Size}]),
    file:close(Fd),
    vg_protocol:decode_message_set(Data,
                                   #{high_water_mark => Offset,
                                     partition => 0,
                                     message_set => []
                                    }).
