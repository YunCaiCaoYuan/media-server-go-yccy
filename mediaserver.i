%module(directors="1") mediaserver
%{

#include <string>
#include <list>
#include <functional>
#include "mediaserver/include/config.h"	
#include "mediaserver/include/dtls.h"
#include "mediaserver/include/OpenSSL.h"
#include "mediaserver/include/media.h"
#include "mediaserver/include/rtp.h"
#include "mediaserver/include/rtpsession.h"
#include "mediaserver/include/DTLSICETransport.h"	
#include "mediaserver/include/RTPBundleTransport.h"
#include "mediaserver/include/PCAPTransportEmulator.h"	
#include "mediaserver/include/mp4recorder.h"
#include "mediaserver/include/mp4streamer.h"
#include "mediaserver/src/vp9/VP9LayerSelector.h"
#include "mediaserver/include/rtp/RTPStreamTransponder.h"
#include "mediaserver/include/ActiveSpeakerDetector.h"


class StringFacade : private std::string
{
public:
	StringFacade(const char* str) 
	{
		std::string::assign(str);
	}
	StringFacade(std::string &str) : std::string(str)
	{
		
	}
	const char* toString() 
	{
		return std::string::c_str();
	}
};


class PropertiesFacade : private Properties
{
public:
	void SetProperty(const char* key,int intval)
	{
		Properties::SetProperty(key,intval);
	}

	void SetProperty(const char* key,const char* val)
	{
		Properties::SetProperty(key,val);
	}
};



class MediaServer
{

public:

	static void Initialize()
	{
		//Initialize ssl
		OpenSSL::ClassInit();
		
		//Start DTLS
		DTLSConnection::Initialize();
	}
	
	static void EnableLog(bool flag)
	{
		//Enable log
		Log("-EnableLog [%d]\n",flag);
		Logger::EnableLog(flag);
		Log("-EnableLog [%d]\n",flag);
	}
	
	static void EnableDebug(bool flag)
	{
		//Enable debug
		Log("-EnableDebug [%d]\n",flag);
		Logger::EnableDebug(flag);
	}
	
	static void EnableUltraDebug(bool flag)
	{
		//Enable debug
		Log("-EnableUltraDebug [%d]\n",flag);
		Logger::EnableUltraDebug(flag);
	}
	
	static bool SetPortRange(int minPort, int maxPort)
	{
		return RTPTransport::SetPortRange(minPort,maxPort);
	}
	
	static StringFacade GetFingerprint()
	{
		return StringFacade(DTLSConnection::GetCertificateFingerPrint(DTLSConnection::Hash::SHA256).c_str());
	}
};


class RTPSessionFacade : 	
	public RTPSender,
	public RTPReceiver,
	public RTPSession
{
public:
	RTPSessionFacade(MediaFrame::Type media) : RTPSession(media,NULL)
	{
		//Delegate to group
		delegate = true;
		//Start group dispatch
		GetIncomingSourceGroup()->Start();
	}
	virtual ~RTPSessionFacade() = default;
	virtual int Enqueue(const RTPPacket::shared& packet)	 { return SendPacket(*packet); }
	virtual int SendPLI(DWORD ssrc)				 { return RequestFPU();}
	
	int Init(const Properties &properties)
	{
		RTPMap rtp;
		RTPMap apt;
		
		//Get codecs
		std::vector<Properties> codecs;
		properties.GetChildrenArray("codecs",codecs);

		//For each codec
		for (auto it = codecs.begin(); it!=codecs.end(); ++it)
		{
			
			BYTE codec;
			//Depending on the type
			switch (GetMediaType())
			{
				case MediaFrame::Audio:
					codec = (BYTE)AudioCodec::GetCodecForName(it->GetProperty("codec"));
					break;
				case MediaFrame::Video:
					codec = (BYTE)VideoCodec::GetCodecForName(it->GetProperty("codec"));
					break;
				case MediaFrame::Text:
					codec = (BYTE)-1;
					break;
			}

			//Get codec type
			BYTE type = it->GetProperty("pt",0);
			//ADD it
			rtp[type] = codec;
		}
	
		//Set local 
		RTPSession::SetSendingRTPMap(rtp,apt);
		RTPSession::SetReceivingRTPMap(rtp,apt);
		
		//Call parent
		return RTPSession::Init();
	}
};

class PlayerFacade :
	public MP4Streamer,
	public MP4Streamer::Listener
{
public:
	PlayerFacade(PlayerListener *listener):
		listener(listener),
		MP4Streamer(this),
		audio(MediaFrame::Audio),
		video(MediaFrame::Video)
	{
		Reset();
		//Start dispatching
		audio.Start();
		video.Start();
	}
		
	virtual void onRTPPacket(RTPPacket &packet)
	{
		switch(packet.GetMedia())
		{
			case MediaFrame::Video:
				//Update stats
				video.media.Update(getTimeMS(),packet.GetSeqNum(),packet.GetRTPHeader().GetSize()+packet.GetMediaLength());
				//Set ssrc of video
				packet.SetSSRC(video.media.ssrc);
				//Multiplex
				video.AddPacket(packet.Clone());
				break;
			case MediaFrame::Audio:
				//Update stats
				audio.media.Update(getTimeMS(),packet.GetSeqNum(),packet.GetRTPHeader().GetSize()+packet.GetMediaLength());
				//Set ssrc of audio
				packet.SetSSRC(audio.media.ssrc);
				//Multiplex
				audio.AddPacket(packet.Clone());
				break;
			default:
				///Ignore
				return;
		}
	}

	virtual void onTextFrame(TextFrame &frame) {}
	virtual void onEnd() 
	{

        // todo make callback 
	}
	
	void Reset() 
	{
		audio.media.Reset();
		video.media.Reset();
		audio.media.ssrc = rand();
		video.media.ssrc = rand();
	}
	
	virtual void onMediaFrame(MediaFrame &frame)  {}
	virtual void onMediaFrame(DWORD ssrc, MediaFrame &frame) {}

	RTPIncomingSourceGroup* GetAudioSource() { return &audio; }
	RTPIncomingSourceGroup* GetVideoSource() { return &video; }
	
private:
	//TODO: Update to multitrack
	PlayerListener *listener;
	RTPIncomingSourceGroup audio;
	RTPIncomingSourceGroup video;
};



class RTPSenderFacade
{
public:	
	RTPSenderFacade(DTLSICETransport* transport)
	{
		sender = transport;
	}

	RTPSenderFacade(RTPSessionFacade* session)
	{
		sender = session;
	}
	
	RTPSender* get() { return sender;}
private:
	RTPSender* sender;
};

class RTPReceiverFacade
{
public:	
	RTPReceiverFacade(DTLSICETransport* transport)
	{
		receiver = transport;
	}

	RTPReceiverFacade(RTPSessionFacade* session)
	{
		receiver = session;
	}
	
	RTPReceiverFacade(PCAPTransportEmulator *transport)
	{
		receiver = transport;
	}
	
	int SendPLI(DWORD ssrc)
	{
		return receiver ? receiver->SendPLI(ssrc) : 0;
	}
	
	RTPReceiver* get() { return receiver;}
private:
	RTPReceiver* receiver;
};


RTPSenderFacade* TransportToSender(DTLSICETransport* transport)
{
	return new RTPSenderFacade(transport);
}
RTPReceiverFacade* TransportToReceiver(DTLSICETransport* transport)
{
	return new RTPReceiverFacade(transport);
}

RTPReceiverFacade* PCAPTransportEmulatorToReceiver(PCAPTransportEmulator* transport)
{
	return new RTPReceiverFacade(transport);
}

RTPSenderFacade* SessionToSender(RTPSessionFacade* session)
{
	return new RTPSenderFacade(session);	
}
RTPReceiverFacade* SessionToReceiver(RTPSessionFacade* session)
{
	return new RTPReceiverFacade(session);
}



class RTPStreamTransponderFacade : 
	public RTPStreamTransponder
{
public:
	RTPStreamTransponderFacade(RTPOutgoingSourceGroup* outgoing,RTPSenderFacade* sender, REMBListener* listener) :
		RTPStreamTransponder(outgoing, sender ? sender->get() : NULL),
		listener(listener)
	{}

	bool SetIncoming(RTPIncomingSourceGroup* incoming, RTPReceiverFacade* receiver)
	{
		return RTPStreamTransponder::SetIncoming(incoming, receiver ? receiver->get() : NULL);
	}
	
	virtual void onREMB(RTPOutgoingSourceGroup* group,DWORD ssrc, DWORD bitrate) override
	{
        // todo  make callback
		Log("onREMB\n");
	}
private:
	REMBListener* listener;
};

class StreamTrackDepacketizer :
	public RTPIncomingSourceGroup::Listener
{
public:
	StreamTrackDepacketizer(RTPIncomingSourceGroup* incomingSource)
	{
		//Store
		this->incomingSource = incomingSource;
		//Add us as RTP listeners
		this->incomingSource->AddListener(this);
		//No depkacketixer yet
		depacketizer = NULL;
	}

	virtual ~StreamTrackDepacketizer()
	{
		//JIC
		Stop();
		//Check 
		if (depacketizer)
			//Delete depacketier
			delete(depacketizer);
	}

	virtual void onRTP(RTPIncomingSourceGroup* group,const RTPPacket::shared& packet)
	{
		//If depacketizer is not the same codec 
		if (depacketizer && depacketizer->GetCodec()!=packet->GetCodec())
		{
			//Delete it
			delete(depacketizer);
			//Create it next
			depacketizer = NULL;
		}
		//If we don't have a depacketized
		if (!depacketizer)
			//Create one
			depacketizer = RTPDepacketizer::Create(packet->GetMedia(),packet->GetCodec());
		//Ensure we have it
		if (!depacketizer)
			//Do nothing
			return;
		//Pass the pakcet to the depacketizer
		 MediaFrame* frame = depacketizer->AddPacket(packet);
		 
		 //If we have a new frame
		 if (frame)
		 {
			 //Call all listeners
			 for (Listeners::const_iterator it = listeners.begin();it!=listeners.end();++it)
				 //Call listener
				 (*it)->onMediaFrame(packet->GetSSRC(),*frame);
			 //Next
			 depacketizer->ResetFrame();
		 }
		
			
	}
	
	virtual void onEnded(RTPIncomingSourceGroup* group) 
	{
		if (incomingSource==group)
			incomingSource = nullptr;
	}
	
	void AddMediaListener(MediaFrame::Listener *listener)
	{
		//Add to set
		listeners.insert(listener);
	}
	
	void RemoveMediaListener(MediaFrame::Listener *listener)
	{
		//Remove from set
		listeners.erase(listener);
	}
	
	void Stop()
	{
		//If already stopped
		if (!incomingSource)
			//Done
			return;
		
		//Stop listeneing
		incomingSource->RemoveListener(this);
		//Clean it
		incomingSource = NULL;
	}
	
private:
	typedef std::set<MediaFrame::Listener*> Listeners;
private:
	Listeners listeners;
	RTPDepacketizer* depacketizer;
	RTPIncomingSourceGroup* incomingSource;
};


class SenderSideEstimatorListener : 
	public RemoteRateEstimator::Listener
{
public:
	SenderSideEstimatorListener(TargetBitrateListener *listener)
		: listener(listener)
	{
		
	}
	
	virtual void onTargetBitrateRequested(DWORD bitrate) override 
	{
        // todo make callback
	}
private:
	TargetBitrateListener* listener;
};


class LayerSources : public std::vector<LayerSource*>
{
public:
	size_t size() const		{ return std::vector<LayerSource*>::size(); }
	LayerSource* get(size_t i)	{ return  std::vector<LayerSource*>::at(i); }
};

class ActiveSpeakerDetectorFacade :
	public ActiveSpeakerDetector,
	public ActiveSpeakerDetector::Listener,
	public RTPIncomingSourceGroup::Listener
{
public:	
	ActiveSpeakerDetectorFacade() :
		ActiveSpeakerDetector(this)
	{};
		
	virtual void onActiveSpeakerChanded(uint32_t id) override
	{
        // todo make callback
	}
	
	void AddIncomingSourceGroup(RTPIncomingSourceGroup* incoming)
	{
		if (incoming) incoming->AddListener(this);
	}
	
	void RemoveIncomingSourceGroup(RTPIncomingSourceGroup* incoming)
	{
		if (incoming)
		{	
			ScopedLock lock(mutex);
			incoming->RemoveListener(this);
			ActiveSpeakerDetector::Release(incoming->media.ssrc);
		}
	}
	
	virtual void onRTP(RTPIncomingSourceGroup* group,const RTPPacket::shared& packet) override
	{
		if (packet->HasAudioLevel())
		{
			ScopedLock lock(mutex);
			ActiveSpeakerDetector::Accumulate(packet->GetSSRC(), packet->GetVAD(),packet->GetLevel(), getTimeMS());
		}
	}		
	
	
	virtual void onEnded(RTPIncomingSourceGroup* group) override
	{
		
	}
private:
	Mutex mutex;
};

%}

%include <typemaps.i>
%include "stdint.i"
%include "std_vector.i"
%include "mediaserver/include/config.h"	
%include "mediaserver/include/media.h"
%include "mediaserver/include/acumulator.h"
%include "mediaserver/include/DTLSICETransport.h"
%include "mediaserver/include/RTPBundleTransport.h"
%include "mediaserver/include/PCAPTransportEmulator.h"
%include "mediaserver/include/mp4recorder.h"
%include "mediaserver/include/rtp/RTPStreamTransponder.h"


%feature("director") PlayerListener;
%feature("director") REMBListener;
%feature("director") TargetBitrateListener;


struct LayerInfo
{
	static BYTE MaxLayerId; 
	BYTE temporalLayerId = MaxLayerId;
	BYTE spatialLayerId  = MaxLayerId;
};

struct LayerSource : public LayerInfo
{
	DWORD		numPackets;
	DWORD		totalBytes;
	Acumulator	bitrate;
};

class LayerSources : public std::vector<LayerSource*>
{
public:
	size_t size() const;
	LayerSource* get(size_t i);
};

struct RTPSource 
{
	DWORD ssrc;
	DWORD extSeq;
	DWORD cycles;
	DWORD jitter;
	DWORD numPackets;
	DWORD numRTCPPackets;
	DWORD totalBytes;
	DWORD totalRTCPBytes;
	Acumulator bitrate;
};

struct RTPIncomingSource : public RTPSource
{
	DWORD lostPackets;
	DWORD totalPacketsSinceLastSR;
	DWORD totalBytesSinceLastSR;
	DWORD minExtSeqNumSinceLastSR ;
	DWORD lostPacketsSinceLastSR;
	QWORD lastReceivedSenderNTPTimestamp;
	QWORD lastReceivedSenderReport;
	QWORD lastReport;
	DWORD totalPLIs;
	DWORD totalNACKs;
	
	%extend 
	{
		LayerSources layers() 
		{
			LayerSources layers;
			for(auto it = $self->layers.begin(); it != $self->layers.end(); ++it )
				layers.push_back(&(it->second));
			return layers;
		}
	}
};
	
struct RTPOutgoingSource : public RTPSource
{
	
	DWORD time;
	DWORD lastTime;
	DWORD numPackets;
	DWORD numRTCPPackets;
	DWORD totalBytes;
	DWORD totalRTCPBytes;
	QWORD lastSenderReport;
	QWORD lastSenderReportNTP;
};

struct RTPOutgoingSourceGroup
{
	RTPOutgoingSourceGroup(MediaFrame::Type type);
	RTPOutgoingSourceGroup(std::string &streamId,MediaFrame::Type type);
	
	MediaFrame::Type  type;
	RTPOutgoingSource media;
	RTPOutgoingSource fec;
	RTPOutgoingSource rtx;
};

struct RTPIncomingSourceGroup
{
	RTPIncomingSourceGroup(MediaFrame::Type type);
	std::string rid;
	std::string mid;
	DWORD rtt;
	MediaFrame::Type  type;
	RTPIncomingSource media;
	RTPIncomingSource fec;
	RTPIncomingSource rtx;
	void Update();
	DWORD GetCurrentLost();
	DWORD GetMinWaitedTime();
	DWORD GetMaxWaitedTime();
	double GetAvgWaitedTime();
};



class StringFacade : private std::string
{
public:
	StringFacade(const char* str);
	StringFacade(std::string &str);
	const char* toString();
};

class PropertiesFacade : private Properties
{
public:
	void SetProperty(const char* key,int intval);
	void SetProperty(const char* key,const char* val);
	void SetProperty(const char* key,bool boolval);
};

class MediaServer
{
public:
	static void Initialize();
	static void EnableLog(bool flag);
	static void EnableDebug(bool flag);
	static void EnableUltraDebug(bool flag);
	static StringFacade GetFingerprint();
	static bool SetPortRange(int minPort, int maxPort);
};



class RTPSessionFacade :
	public RTPSender,
	public RTPReceiver
{
public:
	RTPSessionFacade(MediaFrame::Type media);
	int Init(const Properties &properties);
	int SetLocalPort(int recvPort);
	int GetLocalPort();
	int SetRemotePort(char *ip,int sendPort);
	RTPOutgoingSourceGroup* GetOutgoingSourceGroup();
	RTPIncomingSourceGroup* GetIncomingSourceGroup();
	int End();
	virtual int Enqueue(const RTPPacket::shared& packet);
	virtual int SendPLI(DWORD ssrc);
};



class RTPSenderFacade
{
public:	
	RTPSenderFacade(DTLSICETransport* transport);
	RTPSenderFacade(RTPSessionFacade* session);
	RTPSender* get();

};

class RTPReceiverFacade
{
public:	
	RTPReceiverFacade(DTLSICETransport* transport);
	RTPReceiverFacade(RTPSessionFacade* session);
	RTPReceiverFacade(PCAPTransportEmulator *transport);
	RTPReceiver* get();
	int SendPLI(DWORD ssrc);
};


RTPSenderFacade*	TransportToSender(DTLSICETransport* transport);
RTPReceiverFacade*	TransportToReceiver(DTLSICETransport* transport);
RTPReceiverFacade*	PCAPTransportEmulatorToReceiver(PCAPTransportEmulator* transport);
RTPSenderFacade*	SessionToSender(RTPSessionFacade* session);
RTPReceiverFacade*	SessionToReceiver(RTPSessionFacade* session);


class REMBListener {
public:
	virtual void onREMB() {}
};

class RTPStreamTransponderFacade 
{
public:
	RTPStreamTransponderFacade(RTPOutgoingSourceGroup* outgoing,RTPSenderFacade* sender,REMBListener *listener);
	bool SetIncoming(RTPIncomingSourceGroup* incoming, RTPReceiverFacade* receiver);
	void SelectLayer(int spatialLayerId,int temporalLayerId);
	void Mute(bool muting);
	void Close();
};

class StreamTrackDepacketizer 
{
public:
	StreamTrackDepacketizer(RTPIncomingSourceGroup* incomingSource);
	void AddMediaListener(MediaFrame::Listener* listener);
	void RemoveMediaListener(MediaFrame::Listener* listener);
	void Stop();
};


class PlayerListener {
public:
	virtual void onEnd() {}
};

class PlayerFacade
{
public:
	PlayerFacade();
	RTPIncomingSourceGroup* GetAudioSource();
	RTPIncomingSourceGroup* GetVideoSource();
	void Reset();
	
	int Open(const char* filename);
	bool HasAudioTrack();
	bool HasVideoTrack();
	DWORD GetAudioCodec();
	DWORD GetVideoCodec();
	double GetDuration();
	DWORD GetVideoWidth();
	DWORD GetVideoHeight();
	DWORD GetVideoBitrate();
	double GetVideoFramerate();
	int Play();
	QWORD PreSeek(QWORD time);
	int Seek(QWORD time);
	QWORD Tell();
	int Stop();
	int Close();
};


class TargetBitrateListener {
public:
	virtual void onBitrate() {}
};

class SenderSideEstimatorListener :
	public RemoteRateEstimator::Listener
{
public:
	SenderSideEstimatorListener();
};


class ActiveSpeakerDetectorFacade
{
public:	
	ActiveSpeakerDetectorFacade();
	void SetMinChangePeriod(uint32_t minChangePeriod);
	void AddIncomingSourceGroup(RTPIncomingSourceGroup* incoming);
	void RemoveIncomingSourceGroup(RTPIncomingSourceGroup* incoming);
};





