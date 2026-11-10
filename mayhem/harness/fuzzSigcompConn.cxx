// Feeds bytes to a TCP connection's receive path the way Connection::read() does once a peer
// has opened a SigComp-compressed stream (resip/stack/Connection.cxx, USE_SIGCOMP block).
#include <cstring>
#include <memory>

#include "rutil/Fifo.hxx"
#include "rutil/Logger.hxx"
#include "rutil/Random.hxx"
#include "resip/stack/Compression.hxx"
#include "resip/stack/ConnectionBase.hxx"
#include "resip/stack/Transport.hxx"
#include "resip/stack/TransactionMessage.hxx"
#include "resip/stack/Tuple.hxx"

using namespace resip;

namespace
{
class FakeTcpTransport : public Transport
{
public:
   FakeTcpTransport(Fifo<TransactionMessage>& rxFifo, Compression& compression)
      : Transport(rxFifo, 5060, V4, Data("127.0.0.1"), Data::Empty, nullptr, compression)
   {}

   TransportType transport() const override { return TCP; }
   bool isFinished() const override { return true; }
   void process(FdSet&) override {}
   void process() override {}
   void processTransmitQueue() override {}
   void buildFdSet(FdSet&) override {}
   bool isReliable() const override { return true; }
   bool isDatagram() const override { return false; }
   bool shareStackProcessAndSelect() const override { return true; }
   void startOwnProcessing() override {}
   bool hasDataToSend() const override { return false; }
   void setPollGrp(FdPollGrp*) override {}
   unsigned int getFifoSize() const override { return 0; }
   void invokeAfterSocketCreationFunc() const override {}
   void send(std::unique_ptr<SendData>) override {}
};

class SigcompConnection : public ConnectionBase
{
public:
   SigcompConnection(Transport* transport, const Tuple& who, Compression& compression)
      : ConnectionBase(transport, who, compression)
   {}

   // Connection::read(): a stream is compressed iff its first byte is 0b11111xxx and
   // compression is enabled; the format is decided once, on the first bytes received.
   bool feed(const uint8_t* data, size_t size)
   {
      if (size == 0 || (data[0] & 0xf8) != 0xf8 || !mCompression.isEnabled())
      {
         return false;
      }
      mReceivingTransmissionFormat = Compressed;
      while (size > 0)
      {
         std::pair<char*, size_t> writePair = getWriteBuffer();
         size_t chunk = size < writePair.second ? size : writePair.second;
         if (chunk > ChunkSize)
         {
            chunk = ChunkSize;
         }
         memcpy(writePair.first, data, chunk);
         data += chunk;
         size -= chunk;
         decompressNewBytes(static_cast<int>(chunk));
      }
      return true;
   }
};
}

extern "C" int LLVMFuzzerInitialize(int*, char***)
{
   Log::initialize(Log::Cout, Log::None, "fuzzSigcompConn");
   Random::initialize();
   return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
   Compression compression(Compression::DEFLATE);
   Fifo<TransactionMessage> rxFifo;
   FakeTcpTransport transport(rxFifo, compression);
   Tuple who("127.0.0.1", 5070, V4, TCP);
   SigcompConnection connection(&transport, who, compression);

   return connection.feed(data, size) ? 0 : -1;
}
