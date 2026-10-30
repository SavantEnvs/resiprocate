// Wider rutil harness: upstream's fuzzUtil.cxx only reaches DnsUtil::isIpV4/V6Address.
// This one feeds the same bytes to rutil's string/data parsers and codecs as well.
#include <netinet/in.h>

#include "rutil/Coders.hxx"
#include "rutil/Data.hxx"
#include "rutil/DataStream.hxx"
#include "rutil/DigestStream.hxx"
#include "rutil/DnsUtil.hxx"
#include "rutil/Logger.hxx"
#include "rutil/ParseBuffer.hxx"
#include "rutil/XMLCursor.hxx"

using namespace resip;

static void fuzzDnsUtil(const Data& buffer)
{
   DnsUtil::isIpV4Address(buffer);
   DnsUtil::isIpV6Address(buffer);
   DnsUtil::isIpAddress(buffer);
   DnsUtil::canonicalizeIpV6Address(buffer);

   in_addr a4;
   if (DnsUtil::inet_pton(buffer, a4) > 0)
   {
      DnsUtil::inet_ntop(a4);
   }
   in6_addr a6;
   if (DnsUtil::inet_pton(buffer, a6) > 0)
   {
      DnsUtil::inet_ntop(a6);
   }
}

static void fuzzData(const Data& buffer)
{
   buffer.base64decode();
   buffer.base64encode();
   buffer.base64encode(true);
   Base64Coder::decode(buffer);
   Base64Coder::encode(buffer);
   buffer.hex();
   buffer.fromHex();
   buffer.escaped();
   buffer.charEncoded();
   buffer.charUnencoded();
   buffer.urlEncoded();
   buffer.urlDecoded();
   buffer.xmlCharDataEncode();
   buffer.xmlCharDataDecode();
   buffer.md5();
   buffer.caseInsensitivehash();
   buffer.caseInsensitiveTokenHash();

   Data copy(buffer);
   copy.lowercase();
   copy.uppercase();


   // Data::convertInt() & co. are left out: they overflow a signed int on long digit strings
   // (Data.cxx:1717, upstream UB) and would halt the run on every such input.

   DigestStream ds(SHA1);
   ds << buffer;
   ds.getHex();
}

static void fuzzParseBuffer(const Data& buffer)
{
   {
      ParseBuffer pb(buffer);
      pb.skipWhitespace();
      pb.integer();
   }
   {
      ParseBuffer pb(buffer);
      pb.skipToOneOf(" \t:;,=");
      pb.skipChar();
      pb.skipNonWhitespace();
      pb.uInt32();
   }
   {
      ParseBuffer pb(buffer);
      pb.uInt64();
   }
   {
      ParseBuffer pb(buffer);
      pb.uInt8();
   }
   {
      ParseBuffer pb(buffer);
      pb.floatVal();
   }
   {
      ParseBuffer pb(buffer);
      pb.qVal();
   }
   {
      ParseBuffer pb(buffer);
      const char* start = pb.position();
      pb.skipToEndQuote();
      Data out;
      pb.dataUnescaped(out, start);
   }
   {
      ParseBuffer pb(buffer);
      const char* start = pb.skipToChar('<');
      pb.skipToChars("</");
      pb.data(start);
   }
}

static void fuzzXml(const Data& buffer)
{
   ParseBuffer pb(buffer);
   XMLCursor xml(pb);
   int guard = 0;
   do
   {
      xml.getTag();
      xml.getAttributes();
      xml.getValue();
      if (!xml.atLeaf())
      {
         xml.firstChild();
      }
      else if (!xml.nextSibling())
      {
         while (!xml.nextSibling() && xml.parent()) {}
      }
   } while (++guard < 64);
}

extern "C" int LLVMFuzzerInitialize(int *argc, char ***argv) {
   Log::initialize(Log::Cout, Log::None, *argv[0]);
   return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const unsigned char *data,
                                      unsigned long size) {
   const Data buffer(Data::Share, reinterpret_cast<const char*>(data), size);

   fuzzDnsUtil(buffer);

   try { fuzzData(buffer); } catch (BaseException&) {}
   try { fuzzParseBuffer(buffer); } catch (BaseException&) {}
   try { fuzzXml(buffer); } catch (BaseException&) {}

   return 0;
}
