package mediaserver

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"

	native "github.com/notedit/media-server-go/wrapper"
	"github.com/notedit/sdp"
)

// IncomingStream The incoming streams represent the recived Media stream from a remote peer.
type IncomingStream struct {
	Id                                string
	Info                              *sdp.StreamInfo
	Transport                         native.DTLSICETransport
	Receiver                          native.RTPReceiverFacade
	Tracks                            map[string]*IncomingStreamTrack
	OnStreamAddIncomingTrackListeners []func(*IncomingStreamTrack)
	l                                 sync.Mutex
}

// NewIncomingStream  Create new incoming stream
// TODO: make this public
func newIncomingStream(transport native.DTLSICETransport, receiver native.RTPReceiverFacade, info *sdp.StreamInfo) *IncomingStream {
	stream := &IncomingStream{}
	stream.Id = info.GetID()
	stream.Transport = transport
	stream.Receiver = receiver
	stream.Tracks = make(map[string]*IncomingStreamTrack)

	stream.OnStreamAddIncomingTrackListeners = make([]func(*IncomingStreamTrack), 0)

	for _, track := range info.GetTracks() {
		stream.CreateTrack(track)
	}
	return stream
}

// GetID get Id
func (i *IncomingStream) GetID() string {
	return i.Id
}

// GetStreamInfo get stream Info
func (i *IncomingStream) GetStreamInfo() *sdp.StreamInfo {

	info := sdp.NewStreamInfo(i.Id)

	for _, track := range i.Tracks {
		info.AddTrack(track.GetTrackInfo().Clone())
	}
	return info
}

// GetStats Get statistics for all Tracks in the stream
func (i *IncomingStream) GetStats() map[string]map[string]*IncomingAllStats {

	stats := map[string]map[string]*IncomingAllStats{}

	for _, track := range i.Tracks {
		stats[track.GetID()] = track.GetStats()
	}

	return stats
}

// GetTrack Get track by Id
func (i *IncomingStream) GetTrack(trackID string) *IncomingStreamTrack {
	i.l.Lock()
	defer i.l.Unlock()
	return i.Tracks[trackID]
}

// GetTracks Get all Tracks in this stream
func (i *IncomingStream) GetTracks() []*IncomingStreamTrack {
	i.l.Lock()
	defer i.l.Unlock()
	tracks := []*IncomingStreamTrack{}
	for _, track := range i.Tracks {
		tracks = append(tracks, track)
	}
	return tracks
}

// GetAudioTracks get all audio Tracks
func (i *IncomingStream) GetAudioTracks() []*IncomingStreamTrack {
	i.l.Lock()
	defer i.l.Unlock()
	audioTracks := []*IncomingStreamTrack{}
	for _, track := range i.Tracks {
		if strings.ToLower(track.GetMedia()) == "audio" {
			audioTracks = append(audioTracks, track)
		}
	}
	return audioTracks
}

// GetVideoTracks get all video Tracks
func (i *IncomingStream) GetVideoTracks() []*IncomingStreamTrack {
	i.l.Lock()
	defer i.l.Unlock()
	videoTracks := []*IncomingStreamTrack{}
	for _, track := range i.Tracks {
		if strings.ToLower(track.GetMedia()) == "video" {
			videoTracks = append(videoTracks, track)
		}
	}
	return videoTracks
}

// AddTrack Adds an incoming stream track created using the Transpocnder.CreateIncomingStreamTrack to this stream
func (i *IncomingStream) AddTrack(track *IncomingStreamTrack) error {

	i.l.Lock()
	defer i.l.Unlock()
	if _, ok := i.Tracks[track.GetID()]; ok {
		return errors.New("Track Id already present in stream")
	}

	i.Tracks[track.GetID()] = track
	return nil
}

func (i *IncomingStream) RemoveTrack(track *IncomingStreamTrack) error {

	i.l.Lock()
	defer i.l.Unlock()

	delete(i.Tracks, track.GetID())
	return nil
}

// CreateTrack Create new track from a TrackInfo object and add it to this stream
func (i *IncomingStream) CreateTrack(track *sdp.TrackInfo) *IncomingStreamTrack {

	if _, ok := i.Tracks[track.GetID()]; ok {
		return nil
	}

	var mediaType native.MediaFrameType = 0
	if track.GetMedia() == "video" {
		mediaType = 1
	}

	sources := map[string]native.RTPIncomingSourceGroup{}

	encodings := track.GetEncodings()

	if len(encodings) > 0 {

		for _, items := range encodings {

			for _, encoding := range items {

				source := native.NewRTPIncomingSourceGroup(mediaType, i.Transport.GetTimeService())

				mid := track.GetMediaID()

				rid := encoding.GetID()

				source.SetRid(rid)

				if mid != "" {
					source.SetMid(mid)
				}

				params := encoding.GetParams()

				if ssrc, ok := params["ssrc"]; ok {
					ssrcUint, err := strconv.ParseUint(ssrc, 10, 32)
					if err != nil {
						fmt.Println("ssrc parse error ", err)
						continue
					}
					source.GetMedia().SetSsrc(uint(ssrcUint))
					groups := track.GetSourceGroupS()
					for _, group := range groups {
						// check if it is from us
						if group.GetSSRCs() != nil && group.GetSSRCs()[0] == source.GetMedia().GetSsrc() {
							if group.GetSemantics() == "FID" {
								source.GetRtx().SetSsrc(group.GetSSRCs()[1])
							}

							if group.GetSemantics() == "FEC-FR" {
								source.GetFec().SetSsrc(group.GetSSRCs()[1])
							}
						}
					}
				}

				i.Transport.AddIncomingSourceGroup(source)
				sources[rid] = source

				// runtime.SetFinalizer(source, func(source native.RTPIncomingSourceGroup) {
				// 	i.Transport.RemoveIncomingSourceGroup(source)
				// })

			}
		}

	} else if track.GetSourceGroup("SIM") != nil {
		// chrome like simulcast
		SIM := track.GetSourceGroup("SIM")

		ssrcs := SIM.GetSSRCs()

		groups := track.GetSourceGroupS()

		for j, ssrc := range ssrcs {

			source := native.NewRTPIncomingSourceGroup(mediaType, i.Transport.GetTimeService())

			source.GetMedia().SetSsrc(ssrc)

			for _, group := range groups {

				if group.GetSSRCs()[0] == ssrc {

					if group.GetSemantics() == "FID" {
						source.GetRtx().SetSsrc(group.GetSSRCs()[1])
					}

					if group.GetSemantics() == "FEC-FR" {
						source.GetFec().SetSsrc(group.GetSSRCs()[1])
					}
				}
			}

			i.Transport.AddIncomingSourceGroup(source)

			sources[strconv.Itoa(j)] = source

			// runtime.SetFinalizer(source, func(source native.RTPIncomingSourceGroup) {
			// 	i.Transport.RemoveIncomingSourceGroup(source)
			// })
		}

	} else {
		source := native.NewRTPIncomingSourceGroup(mediaType, i.Transport.GetTimeService())

		source.GetMedia().SetSsrc(track.GetSSRCS()[0])

		fid := track.GetSourceGroup("FID")
		fec_fr := track.GetSourceGroup("FEC-FR")

		if fid != nil {
			source.GetRtx().SetSsrc(fid.GetSSRCs()[1])
		} else {
			source.GetRtx().SetSsrc(0)
		}

		if fec_fr != nil {
			source.GetFec().SetSsrc(fec_fr.GetSSRCs()[1])
		} else {
			source.GetFec().SetSsrc(0)
		}

		i.Transport.AddIncomingSourceGroup(source)

		// Append to soruces with empty rid
		sources[""] = source

	}

	incomingTrack := NewIncomingStreamTrack(track.GetMedia(), track.GetID(), i.Receiver, sources)

	i.l.Lock()
	i.Tracks[track.GetID()] = incomingTrack
	i.l.Unlock()

	return incomingTrack
}

// Stop Removes the Media strem from the Transport and also detaches from any attached incoming stream
func (i *IncomingStream) Stop() {

	if i.Transport == nil {
		return
	}

	i.l.Lock()
	defer i.l.Unlock()

	for k, track := range i.Tracks {
		track.Stop()
		delete(i.Tracks, k)
	}

	native.DeleteRTPReceiverFacade(i.Receiver) // other module maybe need delete
	i.Receiver = nil
	i.Transport = nil
}
