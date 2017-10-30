﻿Shader "Hidden/SEGI_C" {
Properties {
	_MainTex ("Base (RGB)", 2D) = "white" {}
}

CGINCLUDE
	#include "UnityCG.cginc"
	#include "SEGI_C.cginc"
	#pragma target 5.0


	struct v2f
	{
		float4 pos : SV_POSITION;
		float4 uv : TEXCOORD0;	
		
		#if UNITY_UV_STARTS_AT_TOP
		half4 uv2 : TEXCOORD1;
		#endif
	};
	
	v2f vert(appdata_img v)
	{
		v2f o;
		
		o.pos = UnityObjectToClipPos (v.vertex);
		o.uv = float4(v.texcoord.xy, 1, 1);		
		
		#if UNITY_UV_STARTS_AT_TOP
			o.uv2 = float4(v.texcoord.xy, 1, 1);				
			if (_MainTex_TexelSize.y < 0.0)
				o.uv.y = 1.0 - o.uv.y;
		#endif
	        	
		return o; 
	}

ENDCG


SubShader
{
	ZTest Off
	Cull Off
	ZWrite Off
	Fog { Mode off }
		
	Pass //0 diffuse GI trace
	{
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4x4 CameraToWorld;
			
			sampler2D _CameraGBufferTexture2;
			
			
			//sampler2D NoiseTexture;

			float hash(uint2 x)
			{
				uint2 q = 1103515245U * ((x >> 1U) ^ (x.yx));
				uint  n = 1103515245U * ((q.x) ^ (q.y >> 3U));
				return float(n) * (1.0 / float(0xffffffffU));
			}
			//float whangHashNoise(uint u, uint v, uint s)
			//{
			//	uint seed = (u * 1664525u + v) + s;

			//	seed = (seed ^ 61u) ^ (seed >> 16u);
			//	seed *= 9u;
			//	seed = seed ^ (seed >> 4u);
			//	seed *= uint(0x27d4eb2d);
			//	seed = seed ^ (seed >> 15u);

			//	float value = float(seed) / (4294967296.0);
			//	return value;
			//}

			float4 frag(v2f input) : SV_Target
			{
				#if UNITY_UV_STARTS_AT_TOP
					float2 coord = input.uv2.xy;
				#else
					float2 coord = input.uv.xy;
				#endif
				
				//Get view space position and view vector
				float4 viewSpacePosition = GetViewSpacePosition(coord);
				//float3 viewVector = normalize(viewSpacePosition.xyz);

				//Get voxel space position
				float4 voxelSpacePosition = mul(CameraToWorld, viewSpacePosition);

				//float3 viewDir = WorldSpaceViewDir(voxelSpacePosition);

				voxelSpacePosition = mul(SEGIWorldToVoxel0, voxelSpacePosition);
				voxelSpacePosition = mul(SEGIVoxelProjection0, voxelSpacePosition);
				voxelSpacePosition.xyz = voxelSpacePosition.xyz * 0.5 + 0.5;
				

				//Prepare for cone trace
				float3 worldNormal = normalize(tex2D(_CameraGBufferTexture2, coord).rgb * 2.0 - 1.0);
				
				float3 voxelOrigin = voxelSpacePosition.xyz + worldNormal.xyz * 0.003 * ConeTraceBias * 1.25 / SEGIVoxelScaleFactor;	//Apply bias of cone trace origin towards the surface normal to avoid self-occlusion artifacts
				
				float3 gi = float3(0.0, 0.0, 0.0);
				float4 traceResult = float4(0,0,0,0);

				const float phi = 1.618033988;
				const float gAngle = phi * PI;


				//Get noise
				float2 noiseCoord = input.uv.xy * _MainTex_TexelSize.zw + _Time.w;// (input.uv.xy * _MainTex_TexelSize.zw) / (64.0).xx;
				//noiseCoord = (input.uv.xy * _MainTex_TexelSize.zw) / (64.0).xx;
				float2 blueNoise = hash(noiseCoord * 64);
				blueNoise.y = hash(noiseCoord.yx * 128);
				//blueNoise.xy = tex2Dlod(NoiseTexture, float4(noiseCoord, 0.0, 0.0)).rg;

				//Trace GI cones
				int numSamples = TraceDirections;
				for (int i = 0; i < numSamples; i++)
				{
					float fi = (float)i + blueNoise.x * StochasticSampling;
					float fiN = fi / numSamples;
					float longitude = gAngle * fi;
					float latitude = (fiN * 2.0 - 1.0);
					latitude += (blueNoise.y * 2.0 - 1.0) * 0.25;
					latitude = asin(latitude);
					
					float3 kernel;
					kernel.x = cos(latitude) * cos(longitude);
					kernel.z = cos(latitude) * sin(longitude);
					kernel.y = sin(latitude);
					
					kernel = normalize(kernel + worldNormal.xyz);


					traceResult += ConeTrace(voxelOrigin.xyz, kernel.xyz, worldNormal.xyz, coord, blueNoise.x, TraceSteps, ConeSize, 1.0, 1.0);
				}
				
				traceResult /= numSamples;
				gi = traceResult.rgb * 1.18;


				return float4(gi, 1.0);
			}
			
		ENDCG
	}
	
	Pass //1 Bilateral Blur
	{
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float2 Kernel;
					
			float4 frag(v2f input) : COLOR0
			{
				float4 blurred = float4(0.0, 0.0, 0.0, 0.0);
				float validWeights = 0.0;
				float depth = LinearEyeDepth(tex2D(_CameraDepthTexture, input.uv.xy).x);
				half3 normal = DecodeViewNormalStereo(tex2D(_CameraDepthNormalsTexture, input.uv.xy));
				float thresh = 0.26;
				
				float3 viewPosition = GetViewSpacePosition(input.uv.xy).xyz;
				float3 viewVector = normalize(viewPosition);
				
				float NdotV = 1.0 / (saturate(dot(-viewVector, normal.xyz)) + 0.1);
				thresh *= 1.0 + NdotV * 2.0;
				
				for (int i = -4; i <= 4; i++)
				{
					float2 offs = Kernel.xy * (i) * _MainTex_TexelSize.xy;
					float sampleDepth = LinearEyeDepth(tex2Dlod(_CameraDepthTexture, float4(input.uv.xy + offs.xy * 1, 0, 0)).x);
					half3 sampleNormal = DecodeViewNormalStereo(tex2Dlod(_CameraDepthNormalsTexture, float4(input.uv.xy  + offs.xy * 1, 0, 0)));
					
					float weight = saturate(1.0 - abs(depth - sampleDepth) / thresh);
					weight *= pow(saturate(dot(sampleNormal, normal)), 14.0);
					
					float4 blurSample = tex2Dlod(_MainTex, float4(input.uv.xy + offs.xy, 0, 0)).rgba;
					blurred += blurSample * weight;
					validWeights += weight;
				}
				
				blurred /= validWeights + 0.0001;
				
				return blurred;
			}		
		
		ENDCG
	}		
	
	Pass //2 Blend with scene
	{
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			sampler2D _CameraGBufferTexture2;
			sampler2D _CameraGBufferTexture1;
			sampler2D GITexture;
			sampler2D Reflections;
			
			
			float4x4 CameraToWorld;
			
			int DoReflections;

			int HalfResolution;
					
			float4 frag(v2f input) : COLOR0
			{
#if UNITY_UV_STARTS_AT_TOP
				float2 coord = input.uv2.xy;
#else
				float2 coord = input.uv.xy;
#endif

				float4 albedoTex = tex2D(_CameraGBufferTexture0, input.uv.xy);
				float3 albedo = albedoTex.rgb;
				float3 gi = tex2D(GITexture, input.uv.xy).rgb;
				float3 scene = tex2D(_MainTex, input.uv.xy).rgb;
				
				gi *= 0.75 + (float)HalfResolution * 0.25;
				
				float3 result = scene + gi * albedoTex.a * albedoTex.rgb;

				if (DoReflections > 0)
				{
					float3 reflections = tex2D(Reflections, input.uv.xy).rgb;

					float4 viewSpacePosition = GetViewSpacePosition(coord);
					float3 viewVector = normalize(viewSpacePosition.xyz);
					float4 worldViewVector = mul(CameraToWorld, float4(viewVector.xyz, 0.0));

					float4 spec = tex2D(_CameraGBufferTexture1, coord);
					float smoothness = spec.a;
					float3 specularColor = spec.rgb;

					float3 worldNormal = normalize(tex2D(_CameraGBufferTexture2, coord).rgb * 2.0 - 1.0);
					float3 reflectionKernel = reflect(worldViewVector.xyz, worldNormal);

					float3 fresnel = pow(saturate(dot(worldViewVector.xyz, reflectionKernel.xyz)) * (smoothness * 0.5 + 0.5), 5.0);
					fresnel = lerp(fresnel, (1.0).xxx, specularColor.rgb);

					fresnel *= saturate(smoothness * 4.0);

					result = lerp(result, reflections, fresnel);
				}

				return float4(result, 1.0);
			}		
		
		ENDCG
	}	
	
	Pass //3 Temporal blend (with unity motion vectors)
	{
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			sampler2D GITexture;
			sampler2D PreviousDepth;
			sampler2D PreviousLocalWorldPos;
			
			
			float4 CameraPosition;
			float4 CameraPositionPrev;
			float4x4 ProjectionPrev;
			float4x4 ProjectionPrevInverse;
			float4x4 WorldToCameraPrev;
			float4x4 CameraToWorldPrev;
			float4x4 CameraToWorld;
			float DeltaTime;
			float BlendWeight;

			sampler2D BlurredGI;
			
			float4 frag(v2f input) : COLOR0
			{
				float3 gi = tex2D(_MainTex, input.uv.xy).rgb;

				//Calculate moments and width of color deviation of neighbors for color clamping
				float3 m1, m2 = (0.0).xxx;
				{
					float width = 0.7;
					float3 samp = tex2D(_MainTex, input.uv.xy + float2(width, width) * _MainTex_TexelSize.xy).rgb;
					m1 = samp;
					m2 = samp * samp;
					samp = tex2D(_MainTex, input.uv.xy + float2(width, -width) * _MainTex_TexelSize.xy).rgb;
					m1 += samp;
					m2 += samp * samp;
					samp = tex2D(_MainTex, input.uv.xy + float2(-width, width) * _MainTex_TexelSize.xy).rgb;
					m1 += samp;
					m2 += samp * samp;
					samp = tex2D(_MainTex, input.uv.xy + float2(-width, -width) * _MainTex_TexelSize.xy).rgb;
					m1 += samp;
					m2 += samp * samp;
				}

				float3 mu = m1 * 0.25;
				float3 sigma = sqrt(max((0.0).xxx, m2 * 0.25 - mu * mu));
				float errorWindow = 0.2 / BlendWeight;
				float3 minc = mu - (errorWindow) * sigma;
				float3 maxc = mu + (errorWindow) * sigma;



				
				//Calculate world space position for current frame
				float depth = tex2Dlod(_CameraDepthTexture, float4(input.uv.xy, 0.0, 0.0)).x;

				#if defined(UNITY_REVERSED_Z)
				depth = 1.0 - depth;
				#endif
				
				float4 currentPos = float4(input.uv.x * 2.0 - 1.0, input.uv.y * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
				
				float4 fragpos = mul(ProjectionMatrixInverse, currentPos);
				float4 thisViewPos = fragpos;
				fragpos = mul(CameraToWorld, fragpos); 
				fragpos /= fragpos.w;
				float4 thisWorldPosition = fragpos;


				//Get motion vectors and calculate reprojection coord
				float2 motionVectors = tex2Dlod(_CameraMotionVectorsTexture, float4(input.uv.xy, 0.0, 0.0)).xy;
				float2 reprojCoord = input.uv.xy - motionVectors.xy;

				
				//Calculate world space position for the previous frame reprojected to the current frame
				float prevDepth = (tex2Dlod(PreviousDepth, float4(reprojCoord + _MainTex_TexelSize.xy * 0.0, 0.0, 0.0)).x);

				#if defined(UNITY_REVERSED_Z)
				prevDepth = 1.0 - prevDepth;
				#endif
				
				float4 previousWorldPosition = mul(ProjectionPrevInverse, float4(reprojCoord.xy * 2.0 - 1.0, prevDepth * 2.0 - 1.0, 1.0));
				previousWorldPosition = mul(CameraToWorldPrev, previousWorldPosition);
				previousWorldPosition /= previousWorldPosition.w;
				

				//Apply blending
				float blendWeight = BlendWeight;

				float3 blurredGI = tex2D(BlurredGI, input.uv.xy).rgb;

				if (reprojCoord.x > 1.0 || reprojCoord.x < 0.0 || reprojCoord.y > 1.0 || reprojCoord.y < 0.0)
				{
					blendWeight = 1.0;
					gi = blurredGI;
				}

				float posSimilarity = saturate(1.0 - distance(previousWorldPosition.xyz, thisWorldPosition.xyz) * 2.0);
				blendWeight = lerp(1.0, blendWeight, posSimilarity);
				gi = lerp(blurredGI, gi, posSimilarity);
				

				float3 prevGI = tex2D(PreviousGITexture, reprojCoord).rgb;
				prevGI = clamp(prevGI, minc, maxc);
				gi = lerp(prevGI, gi, float3(blendWeight, blendWeight, blendWeight));
				
				float3 result = gi;
				return float4(result, 1.0);
			}	
		
		ENDCG
	}
	
	Pass //4 Specular/reflections trace (CURRENTLY UNUSED)
	{
		ZTest Always
	
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4x4 CameraToWorld;
			
			
			sampler2D _CameraGBufferTexture1;
			sampler2D _CameraGBufferTexture2;
			
			
			
			
			int FrameSwitch;

			
			float4 frag(v2f input) : SV_Target
			{
				#if UNITY_UV_STARTS_AT_TOP
					float2 coord = input.uv2.xy;
				#else
					float2 coord = input.uv.xy;
				#endif
				
				float4 spec = tex2D(_CameraGBufferTexture1, coord);

				float4 viewSpacePosition = GetViewSpacePosition(coord);
				float3 viewVector = normalize(viewSpacePosition.xyz);
				float4 worldViewVector = mul(CameraToWorld, float4(viewVector.xyz, 0.0));

				
				/*
				float4 voxelSpacePosition = mul(CameraToWorld, viewSpacePosition);
				float3 worldPosition = voxelSpacePosition.xyz;
				voxelSpacePosition = mul(SEGIWorldToVoxel, voxelSpacePosition);
				voxelSpacePosition = mul(SEGIVoxelProjection, voxelSpacePosition);
				voxelSpacePosition.xyz = voxelSpacePosition.xyz * 0.5 + 0.5;
				*/

				float4 voxelSpacePosition = mul(CameraToWorld, viewSpacePosition);
				voxelSpacePosition = mul(SEGIWorldToVoxel0, voxelSpacePosition);
				voxelSpacePosition = mul(SEGIVoxelProjection0, voxelSpacePosition);
				voxelSpacePosition.xyz = voxelSpacePosition.xyz * 0.5 + 0.5;

				float3 worldNormal = normalize(tex2D(_CameraGBufferTexture2, coord).rgb * 2.0 - 1.0);
				
				float3 voxelOrigin = voxelSpacePosition.xyz + worldNormal.xyz * 0.006 * ConeTraceBias;

				float2 dither = rand(coord + (float)FrameSwitch * 0.11734);
				
				float smoothness = spec.a * 0.5;
				float3 specularColor = spec.rgb;
				
				float4 reflection = (0.0).xxxx;
				
				float3 reflectionKernel = reflect(worldViewVector.xyz, worldNormal);

				float3 fresnel = pow(saturate(dot(worldViewVector.xyz, reflectionKernel.xyz)) * (smoothness * 0.5 + 0.5), 5.0);
				fresnel = lerp(fresnel, (1.0).xxx, specularColor.rgb);
				
				voxelOrigin += worldNormal.xyz * 0.002;
				reflection = SpecularConeTrace(voxelOrigin.xyz, reflectionKernel.xyz, worldNormal.xyz, smoothness, coord, dither.x);
				//reflection = ConeTrace(voxelOrigin.xyz, reflectionKernel.xyz, worldNormal.xyz, input.uv.xy, 0.0, 12, 0.1, 1.0, 1.0, 1.0);

				//reflection = tex3D(SEGIVolumeLevel0, voxelOrigin.xyz) * 10.0;
				//reflection = float4(1.0, 1.0, 1.0, 1.0);

				float3 skyReflection = (reflection.a * SEGISkyColor);
				
				reflection.rgb = reflection.rgb * 0.7 + skyReflection.rgb * 2.4015 * SkyReflectionIntensity;
				
				return float4(reflection.rgb, 1.0);
			}
			
		ENDCG
	}
	
	Pass //5 Get camera depth texture
	{
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4 frag(v2f input) : COLOR0
			{
				float2 coord = input.uv.xy;
				float4 tex = tex2D(_CameraDepthTexture, coord);				
				return tex;
			}	
		
		ENDCG
	}
	
	Pass //6 Get cmmera normals texture
	{
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			
			float4 frag(v2f input) : COLOR0
			{
				float2 coord = input.uv.xy;
				float4 tex = tex2D(_CameraDepthNormalsTexture, coord);				
				return tex;
			}	
		
		ENDCG
	}	
	
	
	Pass //7 Visualize GI
	{
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			sampler2D GITexture;
					
			float4 frag(v2f input) : COLOR0
			{
				float4 albedoTex = tex2D(_CameraGBufferTexture0, input.uv.xy);
				float3 albedo = albedoTex.rgb;
				float3 gi = tex2D(GITexture, input.uv.xy).rgb;
				return float4(gi, 1.0);
			}		
		
		ENDCG
	}	
	
	
	
	Pass //8 Write black
	{
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4 frag(v2f input) : COLOR0
			{
				return float4(0.0, 0.0, 0.0, 1.0);
			}
			
		ENDCG
	}
	
	Pass //9 Visualize slice of GI Volume (CURRENTLY UNUSED)
	{
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag

			float LayerToVisualize;
			int MipLevelToVisualize;
			
			sampler3D SEGIVolumeTexture1;
			
			float4 frag(v2f input) : COLOR0
			{
				return float4(tex3D(SEGIVolumeTexture1, float3(input.uv.xy, LayerToVisualize)).rgb, 1.0);
			}
			
		ENDCG
	}
	
	
	Pass //10 Visualize voxels (trace through GI volumes)
	{
ZTest Always
	
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4x4 CameraToWorld;
			
			sampler2D _CameraGBufferTexture2;
			
			float4 CameraPosition;
			
			float4 frag(v2f input) : SV_Target
			{
				#if UNITY_UV_STARTS_AT_TOP
					float2 coord = input.uv2.xy;
				#else
					float2 coord = input.uv.xy;
				#endif
				
				float4 viewSpacePosition = GetViewSpacePosition(coord);
				float3 viewVector = normalize(viewSpacePosition.xyz);
				float4 worldViewVector = mul(CameraToWorld, float4(viewVector.xyz, 0.0));

				float4 voxelCameraPosition0 = mul(SEGIWorldToVoxel0, float4(CameraPosition.xyz, 1.0));
					   voxelCameraPosition0 = mul(SEGIVoxelProjection0, voxelCameraPosition0);
					   voxelCameraPosition0.xyz = voxelCameraPosition0.xyz * 0.5 + 0.5;

				float3 voxelCameraPosition1 = TransformClipSpace1(voxelCameraPosition0);
				float3 voxelCameraPosition2 = TransformClipSpace2(voxelCameraPosition0);
				float3 voxelCameraPosition3 = TransformClipSpace3(voxelCameraPosition0);
				float3 voxelCameraPosition4 = TransformClipSpace4(voxelCameraPosition0);
				float3 voxelCameraPosition5 = TransformClipSpace5(voxelCameraPosition0);


				float4 result = float4(0,0,0,1);
				float4 trace;


				trace = VisualConeTrace(voxelCameraPosition0.xyz, worldViewVector.xyz, 1.0, 0);
				result.rgb += trace.rgb;
				result.a *= trace.a;

				trace = VisualConeTrace(voxelCameraPosition1.xyz, worldViewVector.xyz, result.a, 1);
				result.rgb += trace.rgb;
				result.a *= trace.a;

				trace = VisualConeTrace(voxelCameraPosition2.xyz, worldViewVector.xyz, result.a, 2);
				result.rgb += trace.rgb;
				result.a *= trace.a;	

				trace = VisualConeTrace(voxelCameraPosition3.xyz, worldViewVector.xyz, result.a, 3);
				result.rgb += trace.rgb;
				result.a *= trace.a;

				trace = VisualConeTrace(voxelCameraPosition4.xyz, worldViewVector.xyz, result.a, 4);
				result.rgb += trace.rgb;
				result.a *= trace.a;

				trace = VisualConeTrace(voxelCameraPosition5.xyz, worldViewVector.xyz, result.a, 5);
				result.rgb += trace.rgb;  
				result.a *= trace.a;
				
				return float4(result.rgb, 1.0);
			}
			
		ENDCG
	}
	
	Pass //11 Bilateral upsample
	{
		CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			//float2 Kernel;
			//
			//float DepthTolerance;
			
			//sampler2D DepthNormalsLow;
			//sampler2D DepthLow;
			//int SourceScale;
			//sampler2D CurrentDepth;
			//sampler2D CurrentNormal;
			
					
			float4 frag(v2f input) : COLOR0
			{
				float4 blurred = float4(0.0, 0.0, 0.0, 0.0);
				float4 blurredDumb = float4(0.0, 0.0, 0.0, 0.0);
				float validWeights = 0.0;
				float depth = LinearEyeDepth(tex2D(_CameraDepthTexture, input.uv.xy).x);

				half3 normal = DecodeViewNormalStereo(tex2D(_CameraDepthNormalsTexture, input.uv.xy));
				float thresh = 0.26;
				
				float3 viewPosition = GetViewSpacePosition(input.uv.xy).xyz;
				float3 viewVector = normalize(viewPosition);
				
				float NdotV = 1.0 / (saturate(dot(-viewVector, normal.xyz)) + 0.1);
				thresh *= 1.0 + NdotV * 2.0;
				
				float4 sample00 = tex2Dlod(_MainTex, float4(input.uv.xy + _MainTex_TexelSize.xy * float2(0.0, 0.0), 0.0, 0.0));
				float4 sample10 = tex2Dlod(_MainTex, float4(input.uv.xy + _MainTex_TexelSize.xy * float2(1.0, 0.0), 0.0, 0.0));
				float4 sample11 = tex2Dlod(_MainTex, float4(input.uv.xy + _MainTex_TexelSize.xy * float2(1.0, 1.0), 0.0, 0.0));
				float4 sample01 = tex2Dlod(_MainTex, float4(input.uv.xy + _MainTex_TexelSize.xy * float2(0.0, 1.0), 0.0, 0.0));
				
				float4 depthSamples = float4(0,0,0,0);
				depthSamples.x = LinearEyeDepth(tex2Dlod(_CameraDepthTexture, float4(input.uv.xy + _MainTex_TexelSize.xy * float2(0.0, 0.0), 0, 0)).x);//TODO? use CurrentDepth ....
				depthSamples.y = LinearEyeDepth(tex2Dlod(_CameraDepthTexture, float4(input.uv.xy + _MainTex_TexelSize.xy * float2(1.0, 0.0), 0, 0)).x);
				depthSamples.z = LinearEyeDepth(tex2Dlod(_CameraDepthTexture, float4(input.uv.xy + _MainTex_TexelSize.xy * float2(1.0, 1.0), 0, 0)).x);
				depthSamples.w = LinearEyeDepth(tex2Dlod(_CameraDepthTexture, float4(input.uv.xy + _MainTex_TexelSize.xy * float2(0.0, 1.0), 0, 0)).x);
				
				half3 normal00 = DecodeViewNormalStereo(tex2D(_CameraDepthNormalsTexture, input.uv.xy + _MainTex_TexelSize.xy * float2(0.0, 0.0)));//TODO? use CurrentNormal ....
				half3 normal10 = DecodeViewNormalStereo(tex2D(_CameraDepthNormalsTexture, input.uv.xy + _MainTex_TexelSize.xy * float2(1.0, 0.0)));
				half3 normal11 = DecodeViewNormalStereo(tex2D(_CameraDepthNormalsTexture, input.uv.xy + _MainTex_TexelSize.xy * float2(1.0, 1.0)));
				half3 normal01 = DecodeViewNormalStereo(tex2D(_CameraDepthNormalsTexture, input.uv.xy + _MainTex_TexelSize.xy * float2(0.0, 1.0)));
				
				float4 depthWeights = saturate(1.0 - abs(depthSamples - depth.xxxx) / thresh);
				
				float4 normalWeights = float4(0,0,0,0);
				normalWeights.x = pow(saturate(dot(normal00, normal)), 24.0);
				normalWeights.y = pow(saturate(dot(normal10, normal)), 24.0);
				normalWeights.z = pow(saturate(dot(normal11, normal)), 24.0);
				normalWeights.w = pow(saturate(dot(normal01, normal)), 24.0);
				
				float4 weights = depthWeights * normalWeights;
				
				float weightSum = dot(weights, float4(1.0, 1.0, 1.0, 1.0));				
								
				if (weightSum < 0.01)
				{
					weightSum = 4.0;
					weights = (1.0).xxxx;
				}
				
				weights /= weightSum;
				
				float2 fractCoord = frac(input.uv.xy * _MainTex_TexelSize.zw);
				
				float4 filteredX0 = lerp(sample00 * weights.x, sample10 * weights.y, fractCoord.x);
				float4 filteredX1 = lerp(sample01 * weights.w, sample11 * weights.z, fractCoord.x);
				
				float4 filtered = lerp(filteredX0, filteredX1, fractCoord.y);
				
				
				return filtered * 3.0;
				
				return blurred;
			}		
		
		ENDCG
	}
	
	
}

Fallback off

}