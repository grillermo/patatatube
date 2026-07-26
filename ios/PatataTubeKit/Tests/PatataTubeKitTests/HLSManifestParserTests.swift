import XCTest
@testable import PatataTubeKit

final class HLSManifestParserTests: XCTestCase {
    func testMediaAssetsExtractsInitAndSegments() {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        segment_00000.m4s
        #EXTINF:6.0,
        segment_00001.m4s
        #EXT-X-ENDLIST
        """

        XCTAssertEqual(
            HLSManifestParser.mediaAssets(inMediaPlaylist: playlist),
            ["init.mp4", "segment_00000.m4s", "segment_00001.m4s"]
        )
    }

    func testMediaAssetsHandlesSubtitlePlaylist() {
        let playlist = """
        #EXTM3U
        #EXTINF:5400.000,
        es.vtt
        #EXT-X-ENDLIST
        """

        XCTAssertEqual(HLSManifestParser.mediaAssets(inMediaPlaylist: playlist), ["es.vtt"])
    }

    func testReferencedPlaylists() {
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="es",NAME="Spanish",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subtitles/es.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,SUBTITLES="subs"
        video.m3u8
        """

        XCTAssertEqual(
            HLSManifestParser.referencedPlaylists(inMasterPlaylist: master),
            ["subtitles/es.m3u8", "video.m3u8"]
        )
    }
}
