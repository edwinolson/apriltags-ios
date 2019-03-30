attribute vec4 position;
attribute mediump vec4 textureCoord;
varying mediump vec2 coord;

uniform mat4 PM;

void main()
{
	gl_Position = PM*position;
	coord = textureCoord.xy;
}
