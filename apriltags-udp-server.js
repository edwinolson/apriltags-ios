// Reads UDP packets set from the IOS app and outputs JSON to stdout
// This is javascript, but won't run in a browser, use Node.js or the like, eg
// node apriltags-udp-server.js
// if you have a recent node installation already, or alternately, 
// if you have docker and don't want to install nodejs, try
// docker run -i --init --publish 7709:7709/udp node:18-alpine node < apriltags-udp-server.js

const dgram = require( 'node:dgram' );
const aprilTagServer = dgram.createSocket('udp4');

aprilTagServer.on('error', (err) => {
  console.log(`aprilTagServer error:\n${err.stack}`);
  aprilTagServer.close();
});

aprilTagServer.on('message', (msg, rinfo) => {
  var dv = new DataView(msg.buffer);
  var versMaj = dv.getInt16(8);
  var versMin = dv.getInt16(10);
  var ndets = dv.getInt32(12);
  var utime = parseInt(dv.getBigUint64(16).toString());
  var msg = { rinfo:rinfo,utime:utime,ndets:ndets,versMaj:versMaj,versMin:versMin, det:new Array(ndets) };
  var tagOffset = 24;
  if ( ndets == 0 ) { return; }
  // console.log(`aprilTagServer got ${ndets} tags at ${utime} from ${rinfo.address}`);

  for( var detidx = 0 ; detidx < ndets; detidx++ ) {
    var id = dv.getInt32( tagOffset );
    var hamming = dv.getInt32( tagOffset + 4 );
    var familyncodes = dv.getInt32( tagOffset + 8 );
    var c0 = dv.getFloat32( tagOffset + 12 );
    var c1 = dv.getFloat32( tagOffset + 16 );
    var p = [
        [ dv.getFloat32( tagOffset + 20 ), dv.getFloat32( tagOffset + 24 ) ],
        [ dv.getFloat32( tagOffset + 28 ), dv.getFloat32( tagOffset + 32 ) ],
        [ dv.getFloat32( tagOffset + 36 ), dv.getFloat32( tagOffset + 40 ) ],
        [ dv.getFloat32( tagOffset + 44 ), dv.getFloat32( tagOffset + 48 ) ] ];
    var H = [
        dv.getFloat32( tagOffset + 52 ), dv.getFloat32( tagOffset + 56 ),
        dv.getFloat32( tagOffset + 60 ), dv.getFloat32( tagOffset + 64 ),
        dv.getFloat32( tagOffset + 68 ), dv.getFloat32( tagOffset + 72 ),
        dv.getFloat32( tagOffset + 76 ), dv.getFloat32( tagOffset + 80 ),
        dv.getFloat32( tagOffset + 84 ) ];
    msg.det[detidx] = { id:id, hamming:hamming, familyncodes:familyncodes, c0:c0, c1:c1, p:p, H:H};
    tagOffset += 88;
  }
  console.log(JSON.stringify(msg));
});

aprilTagServer.on('listening', () => {
  const address = aprilTagServer.address();
  console.log(`aprilTagServer listening ${address.address}:${address.port}`);
});

aprilTagServer.bind(7709);
