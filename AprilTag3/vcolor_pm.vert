attribute vec4 position;
attribute lowp vec4 color;

varying vec4 vcolor;

uniform mat4 PM;

void main()
{
	gl_Position = PM*position;
    vcolor = color;
}
