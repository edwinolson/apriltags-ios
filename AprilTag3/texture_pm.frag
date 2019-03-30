varying highp vec2 coord;
uniform sampler2D videoframe;

void main()
{
	gl_FragColor = texture2D(videoframe, coord);
}


